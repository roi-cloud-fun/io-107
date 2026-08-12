# Cohort operations toolkit

Instructor-side scripts for pre-deploying IO-107 lab environments for a whole
cohort, driving the lab pipelines, and tearing everything down afterwards.

Students do **not** use these — they follow `STUDENT_SETUP.md` and the per-lab
READMEs. `instructor/bootstrap.sh` remains the single-student entry point; these
scripts wrap it for N students.

## Layout assumptions

Every script resolves its own location, so there is nothing to edit:

| Var | Default | Meaning |
|---|---|---|
| `IO107_REPO` | two levels up from this dir | the io-107 checkout |
| `IO107_OPS_DIR` | the checkout's **parent** | working dir for `cohort/`, `.tfplugincache`, run logs |
| `IO107_ACCOUNT_ID` | `aws sts get-caller-identity` | target account |
| `AWS_PROFILE` | `io107` | credentials profile |

`IO107_OPS_DIR` defaults outside the checkout on purpose: per-student state,
plan files and logs must never land in git.

## Scripts

| Script | What it does |
|---|---|
| `deploy_cohort.sh` | one student, sequential; takes `ENABLE_LAB1..4` |
| `deploy_cohort_parallel.sh` | whole cohort. Bootstrap + `init` run sequentially, applies run concurrently in per-student directories. ~20 min vs ~2 h |
| `reseed_labs.sh` | force lab fixtures to re-clone from the GitHub monorepo (`-replace` on the seed resources) and re-trigger pipelines |
| `drive_labs34.sh` | poll labs 3/4 pipelines to a terminal state, auto-approving lab 4's manual gate |
| `remediate_labs34.sh` | apply the fixes students are meant to make, so labs 3/4 can be rehearsed end-to-end |
| `teardown_complete.sh` | 6-phase teardown — **`terraform destroy` alone is not sufficient** |

```bash
./deploy_cohort_parallel.sh                       # everyone
./deploy_cohort_parallel.sh user01 user02         # subset
ENABLE_LAB3=false ENABLE_LAB4=false ./deploy_cohort_parallel.sh
./teardown_complete.sh user01 us-east-1
```

## Things that will bite you

Full detail in `DEPLOY_LOG.md`; the short version:

- **`terraform destroy` is not a complete teardown.** It leaves the Lab 2 SAM
  stack, the Lab 3 pipeline-created stack, CloudWatch log groups, and — for any
  student who finished Lab 4 — an orphaned `-old1` Aurora cluster plus its
  blue/green record. `teardown_complete.sh` handles all of them; phase B is
  load-bearing, do not drop it.
- **Lab 3 and Lab 4 pipelines sitting at `Validate Failed` is CORRECT.** Those
  are deliberately policy-violating fixtures the student remediates. Do not
  "fix" them.
- **Seeding is not idempotent on content.** The seed `triggers` have no content
  hash, so changing the monorepo does nothing until you run `reseed_labs.sh`.
- **Windows/Git only:** the CodeCommit seed push needs `GCM_INTERACTIVE=never`
  (or it hangs), a `GIT_CONFIG_*` credential-helper reset (or every *re*-push
   403s), and `-parallelism=1` (or CodeCommit 429s). All three are already set
  in these scripts.
- **Regions.** The labs used to hardcode `us-east-1`, which stayed invisible
  until the cohort was split across two regions. Fixed, but if a lab misbehaves
  only outside us-east-1, suspect a leftover hardcode first.
- **EC2 vCPU quota** is the usual blocker: ~6 vCPU per student steady (2
  t3.medium nodes + the student's own management EC2). The default quota of 5
  will not run a single environment.
