# Q6 – Monthly Payroll Processing (schema `q6`)

**Purpose:** gross = basic + allowance; net = gross − deduction. Existing payroll rows are never changed when a month is reprocessed.

## Objects
| Part | Object | What it does |
|---|---|---|
| (a) | `employees`, `payroll`, `salary_audit` | non-negative money, boolean `active`, `pay_month` must be day 1, UNIQUE (`employee_id`, `pay_month`); two payroll months (Sep, Oct 2026) |
| (b) | `fn_net_pay(id)` | net pay from current figures; rejects unknown employee or negative net |
| (c) | `pr_process_payroll(month)` | query FOR loop over active employees; `ON CONFLICT DO NOTHING`; any failure aborts the whole call |
| (d) | `trg_employees_salary_audit` | AFTER UPDATE, only when `basic_salary` actually changes |
| (e) | `v_payroll_report` | inner join with no `active` filter, so history of later-inactive staff remains |
| (f) | `idx_payroll_pay_month` | the unique index leads with `employee_id`, so a `pay_month`-only index is needed for month reports |
| (g) | job `q6_process_payroll` | cron `0 2 1 * *`, passes first day of previous month |

## Inspect the job
```sql
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
```
