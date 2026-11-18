# SPDX-License-Identifier: MPL-2.0
# Which workflow runs of a commit the CI/gate reads jobs from. Input: a JSON ARRAY of every
# workflow run of the head SHA. Arg: $gate, the gate's own workflow name.
# Drops the gate's own runs, then keeps the newest run (highest id) per (workflow_id, event):
# an older run of the same workflow and event is superseded by the newer one. The jobs of a
# kept run are read with filter=latest, which discards that run's earlier attempts.
[.[] | select(.name != $gate)]
| group_by([.workflow_id, .event])
| map(max_by(.id))
| sort_by(.id)
