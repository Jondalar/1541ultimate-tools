#!/usr/bin/env bash
# deploy.sh — FTP deployment to Ultimate devices

normalize_deploy_path() {
    case "$DEPLOY_PATH" in /*) ;; *) DEPLOY_PATH="/$DEPLOY_PATH" ;; esac
    case "$DEPLOY_PATH" in */) ;; *) DEPLOY_PATH="${DEPLOY_PATH}/" ;; esac
}

normalize_remote_directory_path() {
    local remote_path=$1

    case "$remote_path" in /*) ;; *) remote_path="/$remote_path" ;; esac
    case "$remote_path" in */) ;; *) remote_path="${remote_path}/" ;; esac
    printf '%s' "$remote_path"
}

remote_path_exists() {
    local remote_host=$1 remote_path=$2
    run_command curl --fail --show-error --silent \
        --user "${DEPLOY_USER}:${DEPLOY_PASS}" \
        --list-only "ftp://${remote_host}${remote_path}" >/dev/null
}

resolve_deploy_path() {
    local target=$1
    local preferred_path

    if [ "$DEPLOY_PATH_EXPLICIT" -eq 1 ]; then
        printf '%s' "$DEPLOY_PATH"
        return 0
    fi

    preferred_path=$(target_default_deploy_path "$target")
    normalize_remote_directory_path "$preferred_path"
}

ensure_remote_path() {
    local remote_host=$1
    local remote_path current_path segment

    remote_path=$(normalize_remote_directory_path "$2")

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "Would ensure remote directory ${remote_path} on ${remote_host}"
        return 0
    fi

    if remote_path_exists "$remote_host" "$remote_path"; then
        return 0
    fi

    current_path=""
    while IFS= read -r segment; do
        [ -n "$segment" ] || continue
        current_path="${current_path}/${segment}"
        log_info "$(quote_command curl --silent --show-error --user "${DEPLOY_USER}:${DEPLOY_PASS}" --quote "MKD ${current_path}" "ftp://${remote_host}/")"
        curl --silent --show-error \
            --user "${DEPLOY_USER}:${DEPLOY_PASS}" \
            --quote "MKD ${current_path}" \
            "ftp://${remote_host}/" >/dev/null 2>&1 || true
    done <<EOF
$(printf '%s' "$remote_path" | tr '/' '\n')
EOF

    if remote_path_exists "$remote_host" "$remote_path"; then
        log_info "Remote directory ready: ${remote_path}"
        return 0
    fi

    log_warn "Could not confirm remote directory ${remote_path} on ${remote_host}; continuing with FTP upload attempt."
    return 1
}

deploy_target() {
    local target=$1
    local artifact remote_name remote_path remote_url

    if [ -z "$DEPLOY_HOST" ]; then
        die_usage "--deploy-host is required for FTP deployment."
    fi

    if [ "$DEPLOY_ONLY" -eq 0 ] && ! contains_value "$target" "${BUILT_TARGETS[@]}"; then
        DEPLOY_FAILED=1
        FAILED_DEPLOYS+=("$target")
        log_error "Skipping deploy for ${target}: its build did not succeed in this run."
        return 1
    fi

    if ! artifact=$(find_existing_artifact "$target"); then
        DEPLOY_FAILED=1
        FAILED_DEPLOYS+=("$target")
        log_error "No local artifact found for ${target}."
        return 1
    fi

    remote_name=$(target_remote_name "$target")
    remote_path=$(resolve_deploy_path "$target")
    ensure_remote_path "$DEPLOY_HOST" "$remote_path" || true
    remote_url="ftp://${DEPLOY_HOST}${remote_path}${remote_name}"

    CURRENT_ACTION="Deploying ${target} via FTP"
    if ! run_command curl --fail --show-error --silent \
            --ftp-create-dirs \
            --user "${DEPLOY_USER}:${DEPLOY_PASS}" \
            -T "$artifact" "$remote_url"; then
        FTP_UPLOAD_FAILED=1
        FAILED_FTP_UPLOADS+=("$target")
        log_error "FTP upload failed for ${target}: ${remote_url}"
        log_warn "Continuing after FTP upload failure for ${target}."
        CURRENT_ACTION=""
        return 0
    fi

    log_success "Uploaded ${artifact} -> ${remote_url}"
    printf '  Trigger the update on the device from the firmware update menu.\n'
    CURRENT_ACTION=""
    return 0
}
