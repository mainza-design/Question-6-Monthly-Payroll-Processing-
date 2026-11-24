/* #####################################################################
   QUESTION 6 - Monthly Payroll Processing
   ##################################################################### */
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6, public;

-- (a) Tables ------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),  -- month start
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- (b) Function ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_basic NUMERIC; v_allow NUMERIC; v_ded NUMERIC; v_net NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    v_net := (v_basic + v_allow) - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) Procedure ---------------------------------------------------------
-- One transaction: if any employee's calculation fails, nothing is inserted.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE) LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;
    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);              -- raises on invalid calculation
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING; -- existing rows untouched
    END LOOP;
END $$;

-- (d) Trigger -----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) continued: seed data ----------------------------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Patrick Mutale', 8000, 1500, 1200, TRUE),
 ('Queen Ngoma',    6500, 1000,  900, TRUE),
 ('Robert Kasonde', 5000,  500,  700, TRUE),   -- becomes inactive later
 ('Sarah Lubinda',  7000, 1000, 1000, FALSE);  -- inactive from the start

CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

UPDATE employees SET active = FALSE WHERE employee_id = 3;       -- no audit row
UPDATE employees SET basic_salary = 9000 WHERE employee_id = 1;  -- audit row
UPDATE employees SET allowance = 1600 WHERE employee_id = 1;     -- no audit row

CALL pr_process_payroll(DATE '2026-10-01');   -- rerun: rows unchanged, no duplicates
SELECT * FROM salary_audit;
SELECT fn_net_pay(1) AS net_now;              -- 9000 + 1600 - 1200 = 9400
-- Failures: CALL pr_process_payroll(DATE '2026-10-15');  -- not month start

-- (e) View --------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no 'active' filter: history kept

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index -------------------------------------------------------------
-- The unique index (employee_id, pay_month) leads with employee_id, so it cannot
-- efficiently answer "all employees for one month". A single-column pay_month index
-- can; it does not duplicate the unique index because its leading column differs.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------
SELECT cron.schedule('q6_process_payroll', '0 2 1 * *',
  $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history:
SELECT jobid, jobname, schedule, command, active FROM cron.job
WHERE jobname = 'q6_process_payroll';
SELECT d.jobid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d JOIN cron.job j USING (jobid)
WHERE j.jobname = 'q6_process_payroll'
ORDER BY d.start_time DESC LIMIT 10;
