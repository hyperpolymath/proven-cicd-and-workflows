# SPDX-License-Identifier: MPL-2.0
# Rebuilds the per-job records the verdict reads from the TWO bulk reads of an evaluation, so the
# gate never lists the jobs of each workflow run (one request per run).
#   $runs   slurped JSON array of every workflow run of the head SHA (actions/runs?head_sha=...)
#   $checks slurped JSON array of every latest check run of the commit (commits/<sha>/check-runs?filter=latest)
# A check run of GitHub Actions has the display name of its job (`<caller job> / <called job>` for a
# job in a reusable workflow) and belongs to the check suite of its workflow run: the join key is the
# run's `check_suite_id` and the check run's `check_suite.id`. A check run whose suite is not the suite
# of a workflow run (a third-party app: SonarCloud, CodeRabbit, ...) matches nothing and is dropped, so
# only GitHub Actions jobs are read. Output: the same job shape the verdict has always taken,
#   {id, name, status, conclusion, run: {id, name, path, status}}.
($runs[0] | map(select(.check_suite_id != null) | {key: (.check_suite_id | tostring), value: .}) | from_entries) as $bySuite
| [ $checks[0][]
    | ($bySuite[(.check_suite.id // "" | tostring)]) as $run
    | select($run != null)
    | {id, name, status, conclusion,
       run: {id: $run.id, name: $run.name, path: $run.path, status: $run.status}} ]
