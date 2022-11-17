#!/usr/bin/env bash
# FILES_OUTPUT_DIRECTORY=""
# INSTALLATION_KUBERNETES_NAMESPACE=""
# INSTALLATION_NAME=""
# SOURCEFIELD_LICENSE_KEY=""
# GITHUB_URL=""
# GITHUB_API_URL=""
# CREATE_INGRESSES=""
# MAIN_DOMAIN_TO_CREATE_SUBDOMAINS_UNDER=""
# DJANGO_SECRET_KEY=""
# FIELD_ENCRYPTION_KEY=""


# Don't modify anything below here...
YES="yes"
NO="no"
TRUE="true"
FALSE="false"
URL_REGEX='^(https://).*$'
FETCHED="fetched"
GENERATED="generated"

NON_URL_REGEX='^(?!https://).*$'

DEFAULT_INSTALLATION_NAME="sourcefield"
DEFAULT_NAMESPACE="sourcefield"

github_url="https://github.com"
github_api_url="https://api.github.com"
create_ingresses="${FALSE}"
main_domain_to_create_subdomains_under=""
django_secret_key_fetched_or_generated="${GENERATED}"
field_encryption_key_fetched_or_generated="${GENERATED}"

# Renders a text based list of options that can be selected by the
# user using up, down and enter keys and returns the chosen option.
#
#   Arguments   : list of options, maximum of 256
#                 "opt1" "opt2" ...
#   Return value: selected index (0 for opt1, 1 for opt2 ...)
function select_option {

    # little helpers for terminal print control and key input
    ESC=$( printf "\033")
    cursor_blink_on()  { printf "$ESC[?25h"; }
    cursor_blink_off() { printf "$ESC[?25l"; }
    cursor_to()        { printf "$ESC[$1;${2:-1}H"; }
    print_option()     { printf "   $1 "; }
    print_selected()   { printf "  $ESC[7m $1 $ESC[27m"; }
    get_cursor_row()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
    key_input()        { read -s -n3 key 2>/dev/null >&2
                         if [[ $key = $ESC[A ]]; then echo up;    fi
                         if [[ $key = $ESC[B ]]; then echo down;  fi
                         if [[ $key = ""     ]]; then echo enter; fi; }

    # initially print empty new lines (scroll down if at bottom of screen)
    for opt; do printf "\n"; done

    # determine current screen position for overwriting the options
    local lastrow=`get_cursor_row`
    local startrow=$(($lastrow - $#))

    # ensure cursor and input echoing back on upon a ctrl+c during read -s
    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local selected=0
    while true; do
        # print options by overwriting the last lines
        local idx=0
        for opt; do
            cursor_to $(($startrow + $idx))
            if [ $idx -eq $selected ]; then
                print_selected "$opt"
            else
                print_option "$opt"
            fi
            ((idx++))
        done

        # user key control
        case `key_input` in
            enter) break;;
            up)    ((selected--));
                   if [ $selected -lt 0 ]; then selected=$(($# - 1)); fi;;
            down)  ((selected++));
                   if [ $selected -ge $# ]; then selected=0; fi;;
        esac
    done

    # cursor position back to normal
    cursor_to $lastrow
    printf "\n"
    cursor_blink_on

    return $selected
}

function text_prompt() {
  local prompt=${1} possible_value=${2} regex_match=${3}
  if [[ "${2}" != "" ]]; then
    echo "${possible_value}"
    return
  fi
  # echo >&2 "${prompt}"
  read -p "${prompt}:  "

  if [[ "${regex_match}" == "" ]]; then
    echo "${value}"
    return
  fi

  if [[ "$value" =~ $regex_match ]]; then
    echo "${value}"
    return
  fi
  echo >&2
  echo >&2 "Invalid response - does not match the following pattern: ${regex_match}"
  text_prompt "${prompt}" "${possible_value}" "${regex_match}"
}

function text_prompt_simple_value_with_default() {
  local prompt=${1} possible_value=${2} default_value=${3}
  if [[ "${2}" != "" ]]; then
    echo "${possible_value}"
    return
  fi
  # echo >&2 "${prompt}  (default: ${default_value})"
  read -p "${prompt}  (default: ${default_value}):  "

  if [[ "${value}" != "" ]]; then
    echo "${value}"
    return
  fi

  echo "${default_value}"
}

function get_github_details() {
  if [[ "${GITHUB_URL}" != "" ]] && [[ "${GITHUB_API_URL}" != "" ]]; then
    github_url=$(echo ${GITHUB_URL} | tr '[:upper:]' '[:lower:]')
    github_api_url=$(echo ${GITHUB_API_URL} | tr '[:upper:]' '[:lower:]')
    return
  fi

  echo >&2 "Are you using GitHub Cloud (github.com) or GitHub Enterprise (custom domain)?"
  options=(${YES} ${NO})
  select_option "${options[@]}"
  choice=$?
  if [[ "${options[$choice]}" == "${YES}" ]]; then
    return
  fi

  github_url=$(text_prompt "GitHub URL" "${GITHUB_URL}" "${URL_REGEX}" | tr '[:upper:]' '[:lower:]')
  github_api_url=$(text_prompt "GitHub API URL" "${GITHUB_API_URL}" "${URL_REGEX}" | tr '[:upper:]' '[:lower:]')
}

function create_ingress_or_skip() {
  if [[ "${CREATE_INGRESSES}" == "${TRUE}" ]] || [[ "${CREATE_INGRESSES}" == "${FALSE}" ]]; then
    create_ingresses="${CREATE_INGRESSES}"
    return
  fi

  echo >&2 "Do you want to create Ingresses using K8s and include in the Helm Chart?  (if no, you will have to do so manually!)"
  options=(${YES} ${NO})
  select_option "${options[@]}"
  choice=$?
  if [[ "${options[$choice]}" == "${NO}" ]]; then
    return
  fi

  cat <<EOF
Add your required ingress annotations under the following sections in ${BASH_SOURCE%/*}/values.yaml (some suggestions provided; installation will fail without provided annotations):
---
backend:
  ingress:
    annotations:
      ...
ui:
  ingress:
    annotations:
      ...

EOF
  create_ingresses="${TRUE}"
  main_domain_to_create_subdomains_under=$(text_prompt "Main domain (we will create sourcefield.* and sourcefield-api.* under this domain; do not include https:// or trailing slashes/periods)" "${main_domain_to_create_subdomains_under}" | tr '[:upper:]' '[:lower:]')
}

function get_or_create_base64_secret_value_from_helm_chart() {
  local values_path=${1} num_bytes=${2}
  value=$(helm get values -n "${installation_kubernetes_namespace}" "${installation_name}" -o json 2> /dev/null | jq -r "${1}")
  if [ "${value}" != "null" ]; then
    echo "${value}"
    case "$values_path" in
      '.sourcefield.backend.env.DJANGO_SECRET_KEY')
        django_secret_key_fetched_or_generated="${FETCHED}"
        ;;
      '.sourcefield.backend.env.FIELD_ENCRYPTION_KEY')
        field_encryption_key_fetched_or_generated="${FETCHED}"
        ;;
      *)
        ;;
    esac
    return
  fi
  echo "$(openssl rand ${num_bytes} | base64)"
}

cat <<EOF
▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜
▌  Welcome to SourceField  -  "move fast & DON'T break things"           ▐
▌========================================================================▐
▌  This script will generate the files you need to install SourceField:  ▐
▌    * values.yaml file                                                  ▐
▌    * install.sh file                                                   ▐
▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟

EOF

files_output_path=$(text_prompt_simple_value_with_default "Destination directory to output the above files" "${FILES_OUTPUT_DIRECTORY}" "${BASH_SOURCE%/*}")
installation_kubernetes_namespace=$(text_prompt_simple_value_with_default "Kubernetes (K8s) namespace for current/previously-installed installation" "${INSTALLATION_KUBERNETES_NAMESPACE}" "${DEFAULT_NAMESPACE}")
installation_name=$(text_prompt_simple_value_with_default "Helm Chart's installed name be" "${INSTALLATION_NAME}" "${DEFAULT_INSTALLATION_NAME}")
sourcefield_license_key=$(text_prompt "Enter your SourceField License Key" "${SOURCEFIELD_LICENSE_KEY}")
echo
get_github_details
create_ingress_or_skip

django_secret_key=$(get_or_create_base64_secret_value_from_helm_chart '.sourcefield.backend.env.DJANGO_SECRET_KEY' 50)
field_encryption_key=$(get_or_create_base64_secret_value_from_helm_chart '.sourcefield.backend.env.FIELD_ENCRYPTION_KEY' 32)

# Output values.yaml file
cat <<EOF > ${files_output_path}/values.yaml
global:
  env:
    SOURCEFIELD_LICENSE_KEY: ${sourcefield_license_key}
    GITHUB_API_BASE_URL: ${github_api_url}

  backend:
    hostName: sourcefield-api.${main_domain_to_create_subdomains_under}
  ui:
    hostName: sourcefield.${main_domain_to_create_subdomains_under}

backend:
  ingress:
    enabled: ${create_ingresses}
    annotations:
      # kubernetes.io/ingress.class: nginx
      # cert-manager.io/cluster-issuer: letsencrypt-prod
      # kubernetes.io/tls-acme: "true"
    hosts:
      - host: sourcefield-api.${main_domain_to_create_subdomains_under} # If enabled, it must match global.backend.hostName
        paths:
          - path: /
            pathType: ImplementationSpecific
    tls:
    - secretName: sourcefield-api-dev
      hosts:
        - sourcefield-api.${main_domain_to_create_subdomains_under}
  env:
    GITHUB_BASE_URL: ${github_url}
    # !!!!!!!!!!!!!! IMPORTANT !!!!!!!!!!!!!!
    # The following 2 values MUST NOT change between installations.
    # If using a CI/CD system, you should fetch these values instead of overriding them!
    DJANGO_SECRET_KEY: # ${django_secret_key_fetched_or_generated}:  ${django_secret_key}
    FIELD_ENCRYPTION_KEY: # ${field_encryption_key_fetched_or_generated}:  ${field_encryption_key}

ui:
  ingress:
    enabled: ${create_ingresses}
    annotations:
      # kubernetes.io/ingress.class: nginx
      # cert-manager.io/cluster-issuer: letsencrypt-prod
      # kubernetes.io/tls-acme: "true"
    hosts:
      - host: sourcefield.${main_domain_to_create_subdomains_under} # If enabled, it must match global.ui.hostName
        paths:
          - path: /
            pathType: ImplementationSpecific
    tls:
    - secretName: sourcefield-dev
      hosts:
        - sourcefield.${main_domain_to_create_subdomains_under}
EOF

# Output install.sh
