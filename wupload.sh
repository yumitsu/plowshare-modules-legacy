#!/bin/bash
#
# wupload.com module
# Copyright (c) 2011 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_WUPLOAD_REGEXP_URL="http://\(www\.\)\?wupload\.com/"

MODULE_WUPLOAD_DOWNLOAD_OPTIONS=""
MODULE_WUPLOAD_DOWNLOAD_RESUME=no
MODULE_WUPLOAD_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_WUPLOAD_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use a free-membership or premium account"
MODULE_WUPLOAD_LIST_OPTIONS=""

# Output an wupload.com file download URL
# $1: cookie file
# $2: wupload.com url
# stdout: real file download link
wupload_download() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_DOWNLOAD_OPTIONS" "$@")"

    local COOKIEFILE="$1"
    local URL="$2"

    if match 'wupload\.com\/folder\/' "$URL"; then
        log_error "This is a directory list, use plowlist!"
        return 1
    fi

    local BASE_URL='http://www.wupload.com'
    local FILE_ID=$(echo "$URL" | parse_quiet '\/file\/' 'file\/\([^/]*\)')

    while retry_limit_not_reached || return 3; do
        local START_HTML=$(curl -c "$COOKIEFILE" "$URL")

        # Sorry! This file has been deleted.
        if match 'This file has been deleted' "$START_HTML"; then
            log_debug "File not found"
            return 254
        fi

        test "$CHECK_LINK" && return 0

        local FILENAME=$(echo "$START_HTML" | parse_quiet "<title>" ">Get \(.*\) on ")

        # post request with empty Content-Length
        WAIT_HTML=$(curl -b "$COOKIEFILE" --data "" -H "X-Requested-With: XMLHttpRequest" \
                --referer "$URL" "${BASE_URL}/file/${FILE_ID}/${FILE_ID}?start=1")

        # <div id="freeUserDelay" class="section CL3">
        if match 'freeUserDelay' "$WAIT_HTML"; then
            local SLEEP=$(echo "$WAIT_HTML" | parse_quiet 'var countDownDelay = ' 'countDownDelay = \([0-9]*\);')
            local form_tm=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm')
            local form_tmhash=$(echo "$WAIT_HTML" | parse_form_input_by_name 'tm_hash')

             wait $((SLEEP)) seconds || return 2

             WAIT_HTML=$(curl -b "$COOKIEFILE" --data "tm=${form_tm}&tm_hash=${form_tmhash}" \
                     -H "X-Requested-With: XMLHttpRequest" --referer "$URL" "${URL}?start=1")

        # <div id="downloadErrors" class="section CL3">
        # - You can only download 1 file at a time.
        elif match "downloadErrors" "$WAIT_HTML"; then
            local MSG=$(echo "$WAIT_HTML" | parse_quiet '<h3><span>' '<span>\([^<]*\)<')
            log_error "error: $MSG"
            break

        # <div id="downloadLink" class="section CL3">
        # wupload is bugged when I requested several parallel download
        # link returned lead to an (302) error..
        elif match 'Download Ready' "$WAIT_HTML"; then
            local FILE_URL=$(echo "$WAIT_HTML" | parse_attr '<a' 'href')
            log_debug "$FILE_URL"
            return 1

        else
            log_debug "no wait delay, go on"
        fi

        # reCaptcha page
        if match 'Please enter the captcha below' "$WAIT_HTML"; then
            local PUBKEY='6LdNWbsSAAAAAIMksu-X7f5VgYy8bZiiJzlP83Rl'
            local IMAGE_FILENAME=$(recaptcha_load_image $PUBKEY)

            if [ -n "$IMAGE_FILENAME" ]; then
                local TRY=1

                while retry_limit_not_reached || return 3; do
                    log_debug "reCaptcha manual entering (loop $TRY)"
                    (( TRY++ ))

                    WORD=$(recaptcha_display_and_prompt "$IMAGE_FILENAME")

                    rm -f $IMAGE_FILENAME

                    [ -n "$WORD" ] && break

                    log_debug "empty, request another image"
                    IMAGE_FILENAME=$(recaptcha_reload_image $PUBKEY "$IMAGE_FILENAME")
                done

                CHALLENGE=$(recaptcha_get_challenge_from_image "$IMAGE_FILENAME")
                HTMLPAGE=$(curl -b "$COOKIEFILE" --data \
                  "recaptcha_challenge_field=$CHALLENGE&recaptcha_response_field=$WORD" \
                  -H "X-Requested-With: XMLHttpRequest" --referer "$URL" \
                  "${URL}?start=1") || return 1

                if match 'Wrong Code. Please try again.' "$HTMLPAGE"; then
                    log_debug "wrong captcha"
                    break
                fi

                local FILE_URL=$(echo "$HTMLPAGE" | parse_quiet 'Download Ready' 'href="\([^"]*\)"')
                if [ -n "$FILE_URL" ]; then
                    log_debug "correct captcha"
                    echo "$FILE_URL"
                    test "$FILENAME" && echo "$FILENAME"
                    return 0
                fi
            fi

            log_error "reCaptcha error"
            break

        else
            log_error "Unknown state, give up!"
            break
        fi

    done
    return 1
}

# Upload a file to wupload using wupload api - http://api.wupload.com/user
# $1: file name to upload
# $2: upload as file name (optional, defaults to $1)
# stdout: download link on wupload
wupload_upload() {
    eval "$(process_options wupload "$MODULE_WUPLOAD_UPLOAD_OPTIONS" "$@")"

    local FILE=$1
    local DESTFILE=${2:-$FILE}
    local BASE_URL="http://api.wupload.com/"

    if ! test "$AUTH"; then
        log_error "anonymous users cannot upload files"
        return 1
    fi

    USER="${AUTH%%:*}"
    PASSWORD="${AUTH#*:}"

    if [ "$AUTH" = "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || \
        { log_error "You must provide a password"; return 4; }
    fi

    # Not secure !
    JSON=$(curl "$BASE_URL/upload?method=getUploadUrl&u=$USER&p=$PASSWORD") || return 1

    # Login failed. Please check username or password.
    if match "Login failed" "$JSON"; then
        log_debug "login failed"
        return 1
    fi

    log_debug "Successfully logged in as $USER member"

    URL=$(echo "$JSON" | parse 'url' ':"\([^"]*json\)"')
    URL=${URL//[\\]/}

    # Upload one file per request
    JSON=$(curl -F "files[]=@$FILE;filename=$(basename_file "$DESTFILE")" "$URL") || return 1

    if ! match "success" "$JSON"; then
        log_error "upload failed"
        return 1
    fi

    LINK=$(echo "$JSON" | parse 'url' ':"\([^"]*\)\",\"size')
    LINK=${LINK//[\\]/}

    echo "$LINK"
    return 0
}

# List a wupload public folder URL
# $1: wupload url
# stdout: list of links
wupload_list() {
    URL="$1"

    if ! match "${MODULE_WUPLOAD_REGEXP_URL}folder\/" "$URL"; then
        log_error "This is not a folder"
        return 1
    fi

    PAGE=$(curl -L "$URL" | grep "<a href=\"${MODULE_WUPLOAD_REGEXP_URL}file/")

    if ! test "$PAGE"; then
        log_error "Wrong folder link (no download link detected)"
        return 1
    fi

    # First pass: print file names (debug)
    while read LINE; do
        FILENAME=$(echo "$LINE" | parse_quiet 'href' '>\([^<]*\)<\/a>')
        log_debug "$FILENAME"
    done <<< "$PAGE"

    # Second pass: print links (stdout)
    while read LINE; do
        LINK=$(echo "$LINE" | parse_attr '<a' 'href')
        echo "$LINK"
    done <<< "$PAGE"

    return 0
}