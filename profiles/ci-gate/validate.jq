# SPDX-License-Identifier: MPL-2.0
# Structural validation of a CI/gate profile (schema_version 2). Slurped input: exactly one
# document. Args: $repository (the repository the gate runs for; the profile must name it),
#       $forbidden (array of status-context names a job may never be called: the gate's own
#       context and the A3 estate-gate name).
# A required check is an identity, not a bare name: the job display name AND the workflow
# file that produces it. Two producers of one display name are two entries.
def clean_string: type == "string" and (explode | all(. >= 32 and . != 127));
def exact($fields): type == "object" and (keys == ($fields | sort));
def repository: clean_string and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$");
def job_name($forbidden):
  clean_string and length > 0 and
  (. == (sub("^\\s+"; "") | sub("\\s+$"; ""))) and
  (. as $c | all($forbidden[]; . != $c));
def workflow_path: clean_string and test("^\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml$");
def entry($forbidden): exact(["job", "workflow"]) and (.job | job_name($forbidden)) and (.workflow | workflow_path);
(length == 1) and
(.[0] |
  exact(["checks", "repository", "schema_version"]) and
  .schema_version == 2 and
  (.repository | repository) and .repository == $repository and
  (.checks | type == "array" and length > 0 and
    all(.[]; entry($forbidden)) and
    length == (map([.workflow, .job]) | unique | length) and
    . == sort_by([.workflow, .job])))
