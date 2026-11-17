# SPDX-License-Identifier: MPL-2.0
# Structural validation of a CI/gate profile. Slurped input: exactly one document.
# Args: $repository (the repository the gate runs for; the profile must name it),
#       $forbidden (array of status-context names the list may never contain: the
#       gate's own context and the A3 estate-gate name).
def clean_string: type == "string" and (explode | all(. >= 32 and . != 127));
def exact($fields): type == "object" and (keys == ($fields | sort));
def repository: clean_string and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$");
def check_name($forbidden):
  clean_string and length > 0 and . == (sub("^\\s+"; "") | sub("\\s+$"; "")) and
  . as $c | (any($forbidden[]; . == $c) | not);
(length == 1) and
(.[0] |
  exact(["checks", "repository", "schema_version"]) and
  .schema_version == 1 and
  (.repository | repository) and .repository == $repository and
  (.checks | type == "array" and length > 0 and length == (unique | length) and
    all(.[]; check_name($forbidden))))
