#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SHELLDOC-IGNORE

add_test_type pylint

PYLINT_TIMER=0

PYLINT=${PYLINT:-$(command -v pylint 2>/dev/null)}
# backward compatibility, do not use
PYLINT_OPTIONS=${PYLINT_OPTIONS:-}
PYLINT_PIP_CMD=$(command -v pip 2>/dev/null)
PYLINT_REQUIREMENTS=false
PYLINT_PIP_USER=true

function pylint_usage
{
  yetus_add_option "--pylint=<path>" "path to pylint executable (default: ${PYLINT})"
  yetus_add_option "--pylint-pip-cmd=<file>" "Command to use for pip when installing requirements.txt (default: ${PYLINT_PIP_CMD})"
  yetus_add_option "--pylint-rcfile=<path>" "pylint configuration file"
  yetus_add_option "--pylint-requirements=<bool>" "pip install requirements.txt (default: ${PYLINT_REQUIREMENTS})"
  yetus_add_option "--pylint-use-user=<bool>" "Use --user for the requirements.txt (default: ${PYLINT_PIP_USER})"
}

function pylint_parse_args
{
  local i

  for i in "$@"; do
    case ${i} in
    --pylint=*)
      PYLINT=${i#*=}
    ;;
    --pylint-options=*)
      # backward compatibility
      PYLINT_OPTIONS=${i#*=}
    ;;
    --pylint-pip-cmd=*)
      PYLINT_PIP_CMD=${i#*=}
    ;;
    --pylint-rcfile=*)
      PYLINT_RCFILE=${i#*=}
    ;;
    --pylint-requirements=*)
      PYLINT_REQUIREMENTS=${i#*=}
    ;;
    --pylint-use-user=*)
      PYLINT_PIP_USER=${i#*=}
    ;;
    esac
  done
}

function pylint_filefilter
{
  local filename=$1

  if [[ ${filename} =~ \.py$ ]]; then
    add_test pylint
  fi
}

function pylint_precheck
{
  if ! verify_command "Pylint" "${PYLINT}"; then
    add_vote_table 0 pylint "Pylint was not available."
    delete_test pylint
  fi

  if [[ "${PYLINT_REQUIREMENTS}" == true ]] && ! verify_command pip "${PYLINT_PIP_CMD}"; then
    add_vote_table 0 pylint "pip command not available. Will process without it."
  fi
}

function pylint_executor
{
  declare repostatus=$1
  declare i
  declare count
  declare pylintStderr=${repostatus}-pylint-stderr.txt
  declare oldpp
  declare -a pylintopts
  declare -a reqfiles

  if ! verify_needed_test pylint; then
    return 0
  fi

  big_console_header "pylint plugin: ${BUILDMODE}"

  start_clock

  # add our previous elapsed to our new timer
  # by setting the clock back
  offset_clock "${PYLINT_TIMER}"

  if [[ "${PYLINT_REQUIREMENTS}" == true ]]; then
    echo "Processing all requirements.txt files. Errors will be ignored."

    if [[ "${PYLINT_PIP_USER}" == true ]]; then
      pylintopts=("--user")
    fi

    reqfiles=()
    for i in "${CHANGED_FILES[@]}"; do
      dirname=$(yetus_abs "${i}")
      dirname=$(dirname "${dirname}")
      if [[ -f "${dirname}/requirements.txt" ]]; then
        reqfiles+=("${dirname}/requirements.txt")
      fi
    done
    yetus_sort_and_unique_array reqfiles
    for i in "${reqfiles[@]}"; do
      "${PYLINT_PIP_CMD}" install "${pylintopts[@]}" -r "${i}" || true
    done
    oldpp=${PYTHONPATH}
    for i in "${HOME}/.local/lib/python"*/site-packages; do
      export PYTHONPATH="${PYTHONPATH:+${PYTHONPATH}:}${i}"
    done
  fi

  # backward compatibility
  # shellcheck disable=SC2206
  pylintopts=(${PYLINT_OPTIONS})

  if [[ -n "${PYLINT_RCFILE}" ]] && [[ -f "${PYLINT_RCFILE}" ]]; then
    pylintopts+=('--rcfile='"${PYLINT_RCFILE}")
  fi

  pylintopts+=('--persistent=n')
  pylintopts+=('--reports=n')
  pylintopts+=('--score=n')

  echo "Running pylint against identified python scripts."
  pushd "${BASEDIR}" >/dev/null || return 1
  for i in "${CHANGED_FILES[@]}"; do
    if [[ ${i} =~ \.py$ && -f ${i} ]]; then
      "${PYLINT}" "${pylintopts[@]}" --msg-template='{path}:{line}: [{msg_id}({symbol}), {obj}] {msg}' "${i}" \
        2>>"${PATCH_DIR}/${pylintStderr}" | "${AWK}" '1<NR' >> "${PATCH_DIR}/${repostatus}-pylint-result.txt"
    fi
  done

  if [[ -n "${oldpp}" ]]; then
    export PYTHONPATH=${oldpp}
  fi

  if [[ -f ${PATCH_DIR}/${pylintStderr} ]]; then
    count=$("${GREP}"  -Evc "^(No config file found|Using config file)" "${PATCH_DIR}/${pylintStderr}")
    if [[ ${count} -gt 0 ]]; then
      add_vote_table -1 pylint "Error running pylint. Please check pylint stderr files."
      add_footer_table pylint "@@BASE@@/${pylintStderr}"
      return 1
    fi
  fi
  rm "${PATCH_DIR}/${pylintStderr}" 2>/dev/null
  popd >/dev/null || return 1
  return 0
}


function pylint_preapply
{
  declare retval

  if ! verify_needed_test pylint; then
    return 0
  fi

  pylint_executor "branch"
  retval=$?

  # keep track of how much as elapsed for us already
  PYLINT_TIMER=$(stop_clock)
  return ${retval}
}

function pylint_postapply
{
  declare numPrepatch
  declare numPostpatch
  declare diffPostpatch
  declare fixedpatch
  declare statstring

  if ! verify_needed_test pylint; then
    return 0
  fi

  pylint_executor patch

  # shellcheck disable=SC2016
  PYLINT_VERSION=$("${PYLINT}" --version 2>/dev/null | "${GREP}" pylint | "${AWK}" '{print $NF}')
  add_footer_table pylint "v${PYLINT_VERSION%,}"

  calcdiffs "${PATCH_DIR}/branch-pylint-result.txt" \
            "${PATCH_DIR}/patch-pylint-result.txt" \
            pylint > "${PATCH_DIR}/diff-patch-pylint.txt"
  numPrepatch=$("${GREP}" -c '^.*:.*: \[.*\] ' "${PATCH_DIR}/branch-pylint-result.txt")
  numPostpatch=$("${GREP}" -c '^.*:.*: \[.*\] ' "${PATCH_DIR}/patch-pylint-result.txt")
  # Exclude Pylint messages from the information category to avoid false positives (see YETUS-309).
  diffPostpatch=$("${GREP}" -c '^.*:.*: \[[^I].*\] ' "${PATCH_DIR}/diff-patch-pylint.txt")

  ((fixedpatch=numPrepatch-numPostpatch+diffPostpatch))

  statstring=$(generic_calcdiff_status "${numPrepatch}" "${numPostpatch}" "${diffPostpatch}" )

  if [[ ${diffPostpatch} -gt 0 ]] ; then
    add_vote_table -1 pylint "${BUILDMODEMSG} ${statstring}"
    add_footer_table pylint "@@BASE@@/diff-patch-pylint.txt"
    return 1
  elif [[ ${fixedpatch} -gt 0 ]]; then
    add_vote_table +1 pylint "${BUILDMODEMSG} ${statstring}"
    return 0
  fi

  add_vote_table +1 pylint "There were no new pylint issues."
  return 0
}

function pylint_postcompile
{
  declare repostatus=$1

  if [[ "${repostatus}" = branch ]]; then
    pylint_preapply
  else
    pylint_postapply
  fi
}
