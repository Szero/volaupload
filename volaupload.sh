#!/usr/bin/env bash
#shellcheck disable=SC2086

if ! OPTS=$(getopt --options hu:r:cn:p:a:t:w \
--longoptions help,upload:,room:,call,nick:,password:,upload-as:,retries:,watch \
-n 'volaupload.sh' -- "$@") ; then
    echo -e "\nFiled parsing options.\n" ; exit 1
fi

#####################################################################################
# You can add ROOM, NICK and/or PASSWORD variable to your shell config as such:     #
# export ROOM="BEEPi" ; export NICK="dude" ; export PASSWORD="cuck" so you wouldn't #
# have to pass them every time you want to upload something. Using parameters will  #
# override variables from the shell config.                                         #
#####################################################################################

#Remove space from IFS so we can upload files that contain spaces.
#I use little hack here, I replaced default separator from space to
#carrige return so we can iterate over the TARGETS variable without
#a fear of splitting filenames.

IFS="$(printf '\r')"
eval set -- "$OPTS"

SERVER="https://volafile.io"
COOKIE="/tmp/cuckie"
RETRIES="3"

while true; do
    case "$1" in
        -h | --help) HELP="true" ; shift ;;
        -u | --upload) TARGETS="${TARGETS}${2}$IFS" ; shift 2 ;;
        -r | --room)
            p="https?://volafile.io/r/([a-zA-Z0-9_-]{5,8}$)"
            if [[ "$2" =~ $p ]]; then
                ROOM="${BASH_REMATCH[1]}"
            else
                pe="^[a-zA-Z0-9_-]{5,8}$"
                if [[ "$2" =~ $pe ]]; then
                    ROOM="${BASH_REMATCH[0]}"
                else
                    echo -e "\nSorry my dude, but your room ID doesn't match Volafile's format!" >&2
                    exit 2
                fi
            fi ; shift 2 ;;
        -c | --call) CALL="true"; shift ;;
        -n | --nick) NICK="$2" ; shift 2 ;;
        -p | --password) PASSWORD="$2" ; shift 2 ;;
        -a | --upload-as) RENAMES="${RENAMES}${2}$IFS" ; shift 2 ;;
        -t | --retries) RETRIES="$2"
            re="^[0-9]$"
            if ! [[ "$RETRIES" =~ $re ]] || [[ "$RETRIES" -lt 0 ]]; then
                echo -e "\nYou wanted to set negative number of retries or ..." >&2
                echo -e "... exceeded maximum retry count.\n" >&2
                exit 3
            fi ; shift 2 ;;
        -w | --watch) WATCHING="true" ; shift ;;
        --) shift;
            until [[ -z "$1" ]]; do
                TARGETS="${TARGETS}${1}$IFS" ; shift
            done ; break ;;
        * ) shift ;;
    esac
done

print_help() {
    echo -e "\nvolaupload.sh help page\n"
    echo -e "-h, --help"
    echo -e "   Show this help message.\n"
    echo -e "-u, --upload <upload_target>"
    echo -e "   Upload a file or whole directory. Every argument that is not prepended"
    echo -e "   with suitable option will be treated as upload target.\n"
    echo -e "-r, --room <room_name>"
    echo -e "   Specifiy upload room. (This plus at least one upload target is the only"
    echo -e "   required option to upload something).\n"
    echo -e "-c, --call <method> <query>"
    echo -e "   Make Rest API call.\n"
    echo -e "-n, --nick <name>"
    echo -e "   Specify name, under which your file(s) will be uploaded.\n"
    echo -e "-p, -pass <password>"
    echo -e "   Specify your account password. If you upload as logged user, file"
    echo -e "   uploads will count towards your file stats on Volafile."
    echo -e "   See https://volafile.io/user/<your_username>\n"
    echo -e "-a, --upload-as <renamed_file>"
    echo -e "   Upload file with custom name. (It won't overwrite the filename in your"
    echo -e "   fielsystem). You can upload multiple renamed files.\n"
    echo -e "   Example:"
    echo -e "       volaupload.sh -r BEPPi file1.jpg file2.png -a funny.jpg -a nasty.png"
    echo -e "   First occurence of -a parameter always renames first given file and so on.\n"
    echo -e "-t, --retries <number>"
    echo -e "   Specify number of retries when upload fails. Defaults to 3."
    echo -e "   You can't retry more than 9 times.\n"
    echo -e "-w, --watch <directory>"
    echo -e "   Makes your script to watch over specific directory. Every file added"
    echo -e "   to that directory will be uploaded to Volafile. (To exit press Ctrl+Z)\n"
    exit 0
}

bad_arg() {
    echo -e "\n\033[33;1m${1}\033[22m: This argument isn't a file or a directory. Skipping ...\033[0m\n"
    echo -e "Use -h or --help to check program usage.\n"
}

proper_exit() { rm -f "$COOKIE"; exit 0; }
failure_exit() {
    for i in "$@"; do
        echo -e "\033[31m$i\033[0m" >&2
    done; rm -f "$COOKIE"; exit 1;
}
#remove cookie on server error to get fresh session for next upload
skip() {
    for i in "$@"; do
        echo -e "\033[31m$i\033[0m" >&2
    done; rm -f "$COOKIE"
}
#Return non zero value when script jgets interrupted with Ctrl+C and remove cookie
trap failure_exit INT

extract() {
    _key=$2
    echo "$1" | (while read -r line; do
        b="$(echo "$line" | cut -d'=' -f1)"
        if [[ "$b" == "$_key" ]]; then
            printf "%s" "$line" | cut -d'=' -f2
            return;
        fi
        done)
}

makeApiCall() {
    method="$1"
    query="$2"
    name="$3"
    password="$4"
    if [[ -n "$name" ]] && [[ -n "$password" ]]; then
        #session "memoization"
        if [[ ! -f "$COOKIE" ]]; then
            curl -1 -H "Origin: ${SERVER}" \
            -H "Referer: ${SERVER}" -H "Accept: text/values" \
            "${SERVER}/rest/login?name=${name}&password=${password}" 2>/dev/null |
            cut -d$'\n' -f1 > "$COOKIE"
        fi
        cookie="$(head -qn 1 "$COOKIE")"
        if [[ "$cookie" == "error.code=403" ]]; then
            return 1
        fi
        curl -1 -b "$cookie" -H "Origin: ${SERVER}" -H "Referer: ${SERVER}" \
            -H "Accept: text/values" "${SERVER}/rest/${method}?${query}" 2>/dev/null
    else
        curl -1 -H "Origin: ${SERVER}" -H "Referer: ${SERVER}" -H "Accept: text/values" \
            "${SERVER}/rest/${method}?${query}" 2>/dev/null
    fi
}

doUpload() {
    file="$1"
    room="$2"
    name="$3"
    pass="$4"
    renamed="$5"

    if [[ -n "$name" ]] && [[ -n "$pass" ]]; then
        response=$(makeApiCall getUploadKey "name=$name&room=$room" "$name" "$pass")
    elif [[ -n "$name" ]]; then
        response=$(makeApiCall getUploadKey "name=$name&room=$room")
    else
        #If user didn't specify name, default it to Volaphile.
        name="Volaphile"
        response=$(makeApiCall getUploadKey "name=$name&room=$room")
    fi

    #shellcheck disable=SC2181
    if [[ "$?" != "0" ]]; then
        failure_exit "\nLogin Error: You used wrong login and/or password my dude." \
                     "You wanna login properly, so those sweet volastats can stack up!\n"
    fi

    error=$(extract "$response" error)

    if [[ -n "$error" ]]; then
        failure_exit "\nError: $error\n"
    fi

    server="https://$(extract "$response" server)"
    key=$(extract "$response" key)
    file_id=$(extract "$response" file_id)

    # -f option makes curl return error 22 on server responses with code 400 and higher
    if [[ -z "$renamed" ]]; then
        echo -e "\n\033[32m<^> Uploading \033[1m$file\033[22m to \033[1m$ROOM\033[22m as \033[1m$name\033[22m\n"
        printf "\033[33m"
        curl --http2 -1 -f -H "Origin: ${SERVER}" -F "file=@\"${file}\"" \
            "${server}/upload?room=${room}&key=${key}" 1>/dev/null
        error="$?"
    else
        echo -e "\n\033[32m<^> Uploading \033[1m$file\033[22m to \033[1m$ROOM\033[22m as \033[1m$name\033[22m\n"
        echo -e "-> File renamed to: \033[1m${renamed}\033[22m\n"
        printf "\033[33m"
        curl --http2 -1 -f -H "Origin: ${SERVER}" -F "file=@\"${file}\";fkilename=\"${renamed}\"" \
            "${server}/upload?room=${room}&key=${key}" 1>/dev/null
        error="$?"
        file="$renamed"
    fi
    printf "\033[0m"
    case "$error" in
        "0" ) #Replace spaces with %20 so my terminal url finder can see links properly.
              file=$(basename "$file" | sed -r "s/ /%20/g" )
              printf "\n\033[35mVola direct link:\033[0m\n"
              printf "\033[1m%s/get/%s/%s\033[0m\n\n" "$SERVER" "$file_id" "$file" ;;
        "6" ) failure_exit "\nRoom with ID of \033[1m$ROOM\033[22m doesn't exist! Closing script.\n" ;;
        "22") skip "\nServer error. Usually caused by gateway timeout.\n" ;;
        *   ) skip "\nError nr \033[1m${error}\033[22m: Upload failed!\n" ;;
    esac
    return $error
}

tryUpload() {
    for (( i = 0; i <= RETRIES; i++ )); do
        if doUpload "$1" "$2" "$3" "$4" "$5" ; then
            return
        fi; sleep 5; echo -e "\nRetrying upload..."
    done
    failure_exit "\nExceeded number of retries... Closing script."
}

howmany() ( set -f; set -- $1; echo $# )
declare -i argc
argc=$(howmany "$TARGETS")

if [[ $argc == 0 ]] || [[ -n $HELP ]]; then
    print_help
elif [[ -z "$NICK" ]] && [[ -n "$PASSWORD" ]]; then
    failure_exit "\nSpecifying password, but not a username? What are you? A silly-willy?\n"
elif [[ -n "$WATCHING" ]] && [[ -n "$ROOM" ]] && [[ $argc == 1 ]]; then
    TARGET=$(echo "$TARGETS" | tr -d "\r")
    if [[ -d "$TARGET" ]]; then
        inotifywait -m "$TARGET" -e close_write -e moved_to |
            while read -r path _ file; do
                tryUpload "${path}${file}" "$ROOM" "$NICK" "$PASSWORD"
            done
    fi
elif [[ $argc == 2 ]] && [[ -n "$CALL" ]]; then
    set -f ; set -- $TARGETS
    makeApiCall "$1" "$2"
    proper_exit
elif [[ $argc -gt 0 ]] && [[ -z "$WATCHING" ]] && [[ -z "$CALL" ]]; then
    set -- $RENAMES
    for t in $TARGETS ; do
        if [[ -d "$t" ]]; then
            shopt -s globstar
            GLOBIGNORE=".:.."
            for f in "${t}"/** ; do
                if [[ -f "$f" ]] && [[ -n "$1" ]]; then
                    tryUpload "${f}" "$ROOM" "$NICK" "$PASSWORD" "${1}.${f##*.}" ; shift
                elif [[ -f "$f" ]]; then
                    tryUpload "${f}" "$ROOM" "$NICK" "$PASSWORD"
                fi
            done
        elif [[ -f "$t" ]] && [[ -n "$1" ]]; then
            tryUpload "$t" "$ROOM" "$NICK" "$PASSWORD" "${1}.${t##*.}" ; shift
        elif [[ -f "$t" ]]; then
            tryUpload "$t" "$ROOM" "$NICK" "$PASSWORD"
        else
            bad_arg "$t" ; shift
        fi
    done
    proper_exit
else
    print_help
fi
