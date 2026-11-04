SET NOCOUNT ON;
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) < 15
    THROW 51000, 'This demo requires SQL Server 2019 or later.', 1;
IF SCHEMA_ID(N'dba') IS NULL
    EXEC(N'CREATE SCHEMA dba AUTHORIZATION dbo;');
GO

DROP PROCEDURE IF EXISTS dba.waiting_tasks;
DROP PROCEDURE IF EXISTS dba.server_overview;
DROP PROCEDURE IF EXISTS dba.query_store_top_queries;
DROP PROCEDURE IF EXISTS dba.query_store_status;
DROP PROCEDURE IF EXISTS dba.query_store_regressions;
DROP PROCEDURE IF EXISTS dba.query_store_query_details;
DROP PROCEDURE IF EXISTS dba.query_store_plan_details;
DROP PROCEDURE IF EXISTS dba.open_transactions;
DROP PROCEDURE IF EXISTS dba.memory_grants;
GO

IF OBJECT_ID(N'dba.DemoLock', N'U') IS NULL
    CREATE TABLE dba.DemoLock
    (
        id int NOT NULL CONSTRAINT PK_DemoLock PRIMARY KEY,
        counter int NOT NULL,
        CONSTRAINT CK_DemoLock_SingleRow CHECK (id = 1)
    );
IF NOT EXISTS (SELECT 1 FROM dba.DemoLock WHERE id = 1)
    INSERT dba.DemoLock (id, counter) VALUES (1, 0);
GO

CREATE OR ALTER PROCEDURE dba.require_diagnostic_access
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @modern bit = CASE WHEN CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) >= 16 THEN 1 ELSE 0 END;
    IF (@modern = 1 AND COALESCE(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE'), 0) <> 1)
        OR (@modern = 0 AND COALESCE(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0) <> 1)
        THROW 51001, 'Diagnostics require VIEW SERVER PERFORMANCE STATE (2022+) or VIEW SERVER STATE (2019).', 1;
END;
GO

-- Adapted from Microsoft Tiger Toolbox usp_WhatsUp; MIT notice: ..\license.md.
-- Source: https://github.com/microsoft/tigertoolbox/blob/fe47c31ec2f7979a994520d546c7abf0b246c832/usp_WhatsUp/usp_whatsup.sql
CREATE OR ALTER PROCEDURE dba.active_requests
    @top_count int = 20,
    @min_elapsed_ms int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    IF @top_count IS NULL OR @top_count NOT BETWEEN 1 AND 100
        THROW 51010, 'top_count must be between 1 and 100.', 1;
    IF @min_elapsed_ms IS NULL OR @min_elapsed_ms NOT BETWEEN 0 AND 86400000
        THROW 51011, 'min_elapsed_ms must be between 0 and 86400000.', 1;
    EXEC dba.require_diagnostic_access;
    SELECT TOP (@top_count) SYSUTCDATETIME() AS observed_at_utc,
        r.session_id, r.request_id, DB_NAME(r.database_id) AS database_name,
        s.program_name, r.status, r.command,
        r.total_elapsed_time AS elapsed_ms, r.cpu_time AS cpu_ms,
        r.logical_reads, r.blocking_session_id, r.wait_type, r.wait_time AS wait_ms,
        r.wait_resource,
        CONVERT(nvarchar(4000), SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
            (CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text)
                ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1)) AS statement_text
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
    WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
        AND r.total_elapsed_time >= @min_elapsed_ms
    ORDER BY r.total_elapsed_time DESC, r.session_id, r.request_id;
END;
GO

-- Adapted from Microsoft Tiger Toolbox usp_WhatsUp; bounded walk is original. MIT notice: ..\license.md.
-- Source: https://github.com/microsoft/tigertoolbox/blob/fe47c31ec2f7979a994520d546c7abf0b246c832/usp_WhatsUp/usp_whatsup.sql
CREATE OR ALTER PROCEDURE dba.blocking_chain
    @top_count int = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @top_count IS NULL OR @top_count NOT BETWEEN 1 AND 100
        THROW 51010, 'top_count must be between 1 and 100.', 1;
    EXEC dba.require_diagnostic_access;
    ;WITH ranked_requests AS
    (
        SELECT session_id, blocking_session_id, wait_type, wait_time, database_id,
            ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY wait_time DESC, request_id) AS rn
        FROM sys.dm_exec_requests
        WHERE session_id <> @@SPID
    ),
    requests AS
    (
        SELECT session_id, blocking_session_id, wait_type, wait_time, database_id
        FROM ranked_requests WHERE rn = 1
    ),
    chain AS
    (
        SELECT r.session_id AS blocked_session_id, r.blocking_session_id AS immediate_blocker_session_id,
            r.blocking_session_id AS current_blocker_session_id, 1 AS chain_depth,
            CONVERT(varchar(8000), CONCAT('|', r.session_id, '|', r.blocking_session_id, '|')) AS session_path
        FROM requests r
        JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
        WHERE r.blocking_session_id <> 0 AND s.is_user_process = 1
        UNION ALL
        SELECT c.blocked_session_id, c.immediate_blocker_session_id,
            r.blocking_session_id, c.chain_depth + 1,
            CONVERT(varchar(8000), CONCAT(c.session_path, r.blocking_session_id, '|'))
        FROM chain c JOIN requests r ON r.session_id = c.current_blocker_session_id
        WHERE r.blocking_session_id <> 0 AND c.chain_depth < 32
            AND CHARINDEX(CONCAT('|', r.blocking_session_id, '|'), c.session_path) = 0
    ),
    terminal AS
    (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY blocked_session_id ORDER BY chain_depth DESC) AS rn
        FROM chain
    )
    SELECT TOP (@top_count) SYSUTCDATETIME() AS observed_at_utc,
        c.blocked_session_id, c.immediate_blocker_session_id,
        c.current_blocker_session_id AS root_blocker_session_id, c.chain_depth,
        c.session_path, DB_NAME(r.database_id) AS blocked_database_name,
        r.wait_type, r.wait_time AS wait_ms, s.status AS root_session_status,
        s.open_transaction_count AS root_open_transaction_count,
        CONVERT(bit, CASE WHEN next_request.blocking_session_id <> 0 THEN 1 ELSE 0 END) AS chain_incomplete
    FROM terminal c
    JOIN requests r ON r.session_id = c.blocked_session_id
    LEFT JOIN sys.dm_exec_sessions s ON s.session_id = c.current_blocker_session_id
    LEFT JOIN requests next_request ON next_request.session_id = c.current_blocker_session_id
    WHERE c.rn = 1
    ORDER BY r.wait_time DESC, c.blocked_session_id
    OPTION (MAXRECURSION 32);
END;
GO

-- Adapted from Microsoft Tiger Toolbox usp_WhatsUp; MIT notice: ..\license.md.
-- Source: https://github.com/microsoft/tigertoolbox/blob/fe47c31ec2f7979a994520d546c7abf0b246c832/usp_WhatsUp/usp_whatsup.sql
CREATE OR ALTER PROCEDURE dba.session_details
    @session_id int
AS
BEGIN
    SET NOCOUNT ON;
    IF @session_id IS NULL OR @session_id NOT BETWEEN 1 AND 32767
        THROW 51012, 'session_id must be between 1 and 32767.', 1;
    EXEC dba.require_diagnostic_access;
    IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE session_id = @session_id AND is_user_process = 1)
        THROW 51013, 'User session no longer exists or is not visible. Refresh the diagnostics.', 1;
    SELECT TOP (1) SYSUTCDATETIME() AS observed_at_utc, s.session_id,
        CONVERT(datetime2(3), s.login_time) AS login_time,
        DB_NAME(COALESCE(r.database_id, s.database_id)) AS database_name,
        s.status AS session_status, r.status AS request_status,
        s.login_name, s.host_name, s.program_name, s.open_transaction_count,
        r.total_elapsed_time AS elapsed_ms, r.cpu_time AS cpu_ms,
        r.blocking_session_id, r.wait_type, r.wait_time AS wait_ms,
        CASE WHEN r.sql_handle IS NOT NULL THEN 'current_request_batch' ELSE 'last_cached_batch_not_current' END AS text_source,
        CONVERT(nvarchar(4000), t.text) AS batch_text
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
    OUTER APPLY (SELECT TOP (1) most_recent_sql_handle FROM sys.dm_exec_connections
        WHERE session_id = s.session_id ORDER BY connect_time DESC, connection_id) c
    OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) t
    WHERE s.session_id = @session_id
    ORDER BY r.total_elapsed_time DESC, r.request_id;
END;
GO

-- Original implementation using Microsoft Learn KILL guidance:
-- https://learn.microsoft.com/sql/t-sql/language-elements/kill-transact-sql
CREATE OR ALTER PROCEDURE dba.kill_session
    @session_id int,
    @expected_login_time datetime2(3),
    @confirm bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@confirm, 0) <> 1
        THROW 51020, 'Explicit confirmation is required to terminate a session.', 1;
    IF @@TRANCOUNT <> 0
        THROW 51021, 'Cannot terminate a session inside an active caller transaction.', 1;
    EXEC dba.require_diagnostic_access;
    IF COALESCE(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY CONNECTION'), 0) <> 1
        THROW 51022, 'Session termination requires ALTER ANY CONNECTION.', 1;
    IF @session_id IS NULL OR @session_id NOT BETWEEN 1 AND 32767
        THROW 51012, 'session_id must be between 1 and 32767.', 1;
    IF @session_id = @@SPID
        THROW 51023, 'Cannot terminate the caller session.', 1;
    IF @expected_login_time IS NULL
        THROW 51024, 'expected_login_time is required; obtain it from session_details.', 1;

    DECLARE @kill nvarchar(32) = N'KILL ' + CONVERT(nvarchar(11), @session_id) + N';';
    IF NOT EXISTS
    (
        SELECT 1 FROM sys.dm_exec_sessions
        WHERE session_id = @session_id AND is_user_process = 1
            AND CONVERT(datetime2(3), login_time) = @expected_login_time
    )
        THROW 51025, 'Session identity changed, disappeared or is not a user session. Refresh session_details.', 1;
    EXEC sys.sp_executesql @kill WITH RESULT SETS NONE;
    SELECT SYSUTCDATETIME() AS observed_at_utc, @session_id AS session_id,
        CONVERT(varchar(21), 'termination_requested') AS status;
END;
GO

-- Original implementation using Microsoft Learn WAITFOR and LOCK_TIMEOUT guidance:
-- https://learn.microsoft.com/sql/t-sql/language-elements/waitfor-transact-sql
-- https://learn.microsoft.com/sql/t-sql/statements/set-lock-timeout-transact-sql
CREATE OR ALTER PROCEDURE dba.cause_problem
    @role varchar(10) = 'blocker',
    @duration_seconds int = 30,
    @confirm bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@confirm, 0) <> 1
        THROW 51030, 'Explicit confirmation is required to run the blocking demo.', 1;
    IF @@TRANCOUNT <> 0
        THROW 51031, 'Cannot run the demo inside an active caller transaction.', 1;
    IF @role IS NULL OR @role NOT IN ('blocker', 'waiter')
        THROW 51032, 'role must be blocker or waiter.', 1;
    IF @duration_seconds IS NULL OR @duration_seconds NOT BETWEEN 5 AND 120
        THROW 51033, 'duration_seconds must be between 5 and 120.', 1;
    SET XACT_ABORT ON;
    IF @role = 'blocker'
        SET LOCK_TIMEOUT 5000;
    ELSE
        SET LOCK_TIMEOUT 120000;
    DECLARE @delay char(8) = CONVERT(char(8), DATEADD(second, @duration_seconds, CONVERT(time(0), '00:00:00')), 108);
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dba.DemoLock SET counter = counter + 1 WHERE id = 1;
        IF @@ROWCOUNT <> 1
            THROW 51034, 'The DemoLock row is missing; redeploy database.sql.', 1;
        IF @role = 'blocker'
            WAITFOR DELAY @delay;
        ROLLBACK TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
    SELECT SYSUTCDATETIME() AS observed_at_utc, @@SPID AS session_id,
        @role AS role, CONVERT(varchar(11), 'rolled_back') AS outcome;
END;
GO
