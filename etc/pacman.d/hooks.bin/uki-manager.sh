#!/usr/bin/env bash
# /etc/pacman.d/hooks.bin/uki-manager.sh

# ------------------------------------------------------------------------------
#                                                                              -
#  UKI Manager Script                                                          -
#                                                                              -
#  Manages UKIs when mkinitcpio and/or kernel packages are installed,          -
#  upgraded or removed. Triggered by package manager hooks '/etc/pac           -
#  man.d/hooks/uki-*.hook' (works for pamac, pacman and GUI manager)           -
#                                                                              -
#  Created by Fonic <https://github.com/fonic>                                 -
#  Date: 04/19/23 - 07/20/25                                                   -
#                                                                              -
#  Based on:                                                                   -
#  /usr/share/libalpm/scripts/mkinitcpio                                       -
#                                                                              -
# ------------------------------------------------------------------------------


# --------------------------------------
#  Globals                             -
# --------------------------------------

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_FILE="${SCRIPT_PATH##*/}"
SCRIPT_NAME="${SCRIPT_FILE%.*}"
SCRIPT_CONF="${SCRIPT_PATH%.*}.conf"
SCRIPT_PID=$$ # required for logger
SCRIPT_ARGC=$#; SCRIPT_ARGV=("$@")


# --------------------------------------
#  Functions                           -
# --------------------------------------

# Read value of variable from mkinitcpio preset file [$1: preset file path,
# $2: preset variable name, $3: target variable name]
#
# Return value and result:
# 0 == preset variable found, value assigned to target variable
# 1 == preset variable not found / unset, target variable unset
# 2 == error occurred (e.g. permission denied), target variable unset
#
# NOTE:
# Commented-out variables (e.g. '#somevar="somevalue"') are considered unset
# and will therefore NOT yield a value, but can be explicitely queried by
# specifying $2 == '#<varname>'; anchor '^' for grep is necessary to prevent
# partial matches (e.g. $2 == '_uki'); reading quoted + dequoting in order
# to be able to read array-style variables (e.g. 'PRESETS=(...)')
#function read_preset_var() {
#    local prefile="$1" prevar="$2" tmpvar
#    local -n dstvar="$3"; unset dstvar # explicitely unset target variable
#    #tmpvar="$(grep -Po "(?<=^${prevar}=\").*(?=\")" "${prefile}")" || { (( $? == 1 )) && return 0 || return 1; }
#    tmpvar="$(grep -Po "(?<=^${prevar}=).*" "${prefile}")" || return $?
#    [[ "${tmpvar}" == \"*\" || "${tmpvar}" == \'*\' ]] && dstvar="${tmpvar:1:-1}" || dstvar="${tmpvar}"
#    return 0
#}

# Read value of variable from mkinitcpio preset file [$1: preset file path,
# $2: preset variable name, $3: target variable name]
#
# Return value and result:
# 0 == preset variable found, value assigned to target variable
# -or- preset variable not found / unset, target variable unset
# 1 == error occurred (e.g. permission denied), target variable unset
#
# NOTE:
# Commented-out variables (e.g. '#somevar="somevalue"') are considered unset
# and will therefore NOT yield a value, but can be explicitely queried by
# specifying $2 == '#<varname>'; anchor '^' for grep is necessary to prevent
# partial matches (e.g. $2 == '_uki'); reading quoted + dequoting in order
# to be able to read array-style variables (e.g. 'PRESETS=(...)')
function read_preset_var() {
    local prefile="$1" prevar="$2" tmpvar
    local -n dstvar="$3"; unset dstvar # explicitely unset target variable
    #tmpvar="$(grep -Po "(?<=^${prevar}=\").*(?=\")" "${prefile}")" || { (( $? == 1 )) && return 0 || return 1; }
    tmpvar="$(grep -Po "(?<=^${prevar}=).*" "${prefile}")" || { (( $? == 1 )) && return 0 || return 1; }
    [[ "${tmpvar}" == \"*\" || "${tmpvar}" == \'*\' ]] && dstvar="${tmpvar:1:-1}" || dstvar="${tmpvar}"
    return 0
}


# --------------------------------------
#  Main                                -
# --------------------------------------

# Set up error handling
set -ue; trap "echo \"Error [BUG]: an unhandled error occurred on line \${LINENO}, aborting.\" >&2; exit 1" ERR

# Read configuration
if ! source "${SCRIPT_CONF}"; then
    echo "Error: failed to read configuration file '${SCRIPT_CONF}', aborting." >&2
    exit 1
fi

# Hook enabled? If not, exit right away (with positive return value)
if ! ${HOOK_ENABLED}; then
    exit 0
fi

# Set up logging
if ${SYSLOG_ENABLED}; then
    # 'logger' is quite picky: it MUST be '--id=PID', '--id PID' won't work;
    # both '--tag TAG' and '--tag=TAG' seem to work, though; PID will only be
    # applied if run as root; embrace the weirdness ;)
    #if ! exec 3>&1 4>&2 || ! exec 1> >(exec logger --id=${SCRIPT_PID} --tag "${LOG_SLID}" --stderr) 2>&1; then # console output will look like syslog messages
    if ! exec 3>&1 4>&2 || ! exec 1> >(while read -r msg; do echo "${msg}"; logger --id=${SCRIPT_PID} --tag "${SCRIPT_NAME}" -- "${msg}"; done) 2>&1; then # more natural console output; '--' before '${msg}' is important to avoid weird side effects!
        echo "Error: failed to set up logging, aborting." >&2
        exit 1
    fi
fi
echo "***** ${SCRIPT_FILE} started | pid: ${SCRIPT_PID}, args (${SCRIPT_ARGC}): '${SCRIPT_ARGV[@]}' *****"
trap "echo \"***** \${SCRIPT_FILE} ended | pid: \${SCRIPT_PID}, args (\${SCRIPT_ARGC}): '\${SCRIPT_ARGV[@]}' *****\"; \${SYSLOG_ENABLED} && { exec 1>&3 2>&4 && exec 3>&- 4>&- || :; }; sleep 0.5s" EXIT # no reason to handle errors as fds are cleaned up anyway when script terminates; using 'sleep' to make sure output has enough time to get flushed

# Process command line
if (( $# != 1 )); then
    echo "Error: invalid number of arguments (expected 1, got $#), aborting." >&2
    exit 2
fi
action="$1"
if [[ "${action}" != "install" && "${action}" != "remove" ]]; then
    echo "Error: invalid action '${action}', aborting." >&2
    exit 2
fi

# Read and process triggers from stdin
mkinitcpio_trigger="false"; kernel_triggers=()
while read -r line; do

    # Mkinitcpio package trigger?
    # Due to trailing wildcard in hook targets and wildcard matching below,
    # this can occur MULTIPLE times per script run (once per modified package
    # item), but corresponding tasks need to be performed ONLY ONCE per run
    if [[ "${line}" == *"usr/lib/initcpio/"* ]]; then
        ${mkinitcpio_trigger} && continue # silence further triggers
        echo "Mkinitcpio package trigger detected: '${line}'"
        mkinitcpio_trigger="true"

    # Kernel package trigger?
    # Due to trailing '/vmlinuz', this should only occur ONCE per modified
    # kernel package
    elif [[ "${line}" == *"usr/lib/modules/"*"/vmlinuz" ]]; then
        echo "Kernel package trigger detected: '${line}'"
        kernel_triggers+=("${line}")

    # Unknown trigger (should never occur)
    else
        echo "Error: unknown trigger: '${line}'" >&2
        continue
    fi

done

# Perform tasks for requested action
result=0
if [[ "${action}" == "install" ]]; then

    # For each kernel package that is being installed/upgraded:
    # Modify mkinitcpio preset file to generate UKI files, (re-)build UKI files
    # (via mkinitcpio), sign UKI files for Secure Boot, create UEFI boot manager
    # entries
    for kernel_trigger in "${kernel_triggers[@]}"; do
        kernel_dir="${kernel_trigger%/vmlinuz}" # e.g. '/usr/lib/modules/6.1.25'
        kernel_name="${kernel_dir##*/}" # e.g. '6.1.25'
        echo "Kernel package installed/upgraded, configuring/(re-)building UKIs for kernel '${kernel_name}':"

        # Gather information from kernel directory
        echo "Gathering information from kernel directory '${kernel_dir}'..."
        if ! read -r pkgbase < "${kernel_dir}/pkgbase"; then # e.g. 'linux61'
            echo "Error: failed to read pkgbase from '${kernel_dir}/pkgbase'" >&2
            result=1; continue
        fi
        if ! read -r kernelbase < "${kernel_dir}/kernelbase"; then # e.g. '6.1-x86_64'
            echo "Error: failed to read kernelbase from '${kernel_dir}/kernelbase'" >&2
            result=1; continue
        fi
        echo "pkgbase: '${pkgbase}', kernelbase: '${kernelbase}'"

        # Define paths of mkinitcpio preset file and UKI files
        printf -v preset_file "${PRESET_BASE}/${PRESET_FILE}" "${pkgbase}"
        printf -v uki_df_file "${UKI_BASE}/${UKI_DF_FILE}" "${pkgbase}"
        printf -v uki_fb_file "${UKI_BASE}/${UKI_FB_FILE}" "${pkgbase}"

        # Check if mkinitcpio preset file exists (cannot continue without),
        # read variables related to UKI use (might be set or commented-out/
        # unset)
        echo "Checking and reading mkinitcpio preset file '${preset_file##*/}'..."
        if [[ ! -f "${preset_file}" ]]; then
            echo "Error: mkinitcpio preset file '${preset_file}' does not exist" >&2
            result=1; continue
        fi
        if ! read_preset_var "${preset_file}" "PRESETS" presets ||
           ! read_preset_var "${preset_file}" "default_uki" default_uki ||
           ! read_preset_var "${preset_file}" "default_options" default_options ||
           ! read_preset_var "${preset_file}" "fallback_uki" fallback_uki ||
           ! read_preset_var "${preset_file}" "fallback_options" fallback_options
        then
            echo "Error: failed to read mkinitcpio preset file '${preset_file}'" >&2
            result=1; continue
        fi
        echo "PRESETS: ${presets-"<not set>"}"
        echo "default_uki: ${default_uki-"<not set>"}, default_options: ${default_options-"<not set>"}"
        echo "fallback_uki: ${fallback_uki-"<not set>"}, fallback_options: ${fallback_options-"<not set>"}"

        # Configure mkinitcpio preset file for UKI use (if not already properly
        # configured, i.e. one or more variables are unset or set to different
        # than expected values)
        echo "Configuring mkinitcpio preset file '${preset_file##*/}' for UKI use..."
        if [[ -z "${presets+set}" ]] || [[ "${presets}" != "('default' 'fallback')" ]] ||
           [[ -z "${default_uki+set}" ]] || [[ "${default_uki}" != "${uki_df_file}" ]] ||
           [[ -z "${default_options+set}" ]] || [[ "${default_options}" != "${UKI_DF_OPTS}" ]] ||
           [[ -z "${fallback_uki+set}" ]] || [[ "${fallback_uki}" != "${uki_fb_file}" ]] ||
           [[ -z "${fallback_options+set}" ]] || [[ "${fallback_options}" != "${UKI_FB_OPTS}" ]]
        then
            if ! sed -i -e "s|^#\{0,1\}PRESETS=.*|PRESETS=('default' 'fallback')|g" "${preset_file}" ||                # enable 'PRESETS' line, configure for default + fallback
              #! sed -i -e "s|^default_.*|#&|g" "${preset_file}" ||                                                    # disable all 'default_=' lines (optional)
               ! sed -i -e "s|^#\{0,1\}default_uki=.*|default_uki=\"${uki_df_file}\"|g" "${preset_file}" ||            # enable 'default_uki=' line, apply default UKI file path
               ! sed -i -e "s|^#\{0,1\}default_options=.*|default_options=\"${UKI_DF_OPTS}\"|g" "${preset_file}" ||    # enable 'default_options=' line, apply default UKI options
              #! sed -i -e "s|^fallback_.*|#&|g" "${preset_file}" ||                                                   # disable all 'fallback_=' lines (optional)
               ! sed -i -e "s|^#\{0,1\}fallback_uki=.*|fallback_uki=\"${uki_fb_file}\"|g" "${preset_file}" ||          # enable 'fallback_uki=' line, apply fallback UKI file path
               ! sed -i -e "s|^#\{0,1\}fallback_options=.*|fallback_options=\"${UKI_FB_OPTS}\"|g" "${preset_file}"     # enable 'fallback_options=' line, apply fallback UKI options
            then
                echo "Error: failed to configure mkinitcpio preset file '${preset_file}' for UKI use" >&2
                result=1; continue
            fi
            preset_modified="true"
        else
            #echo "Mkinitcpio preset file '${preset_file##*/}' is already configured for UKI use."
            echo "Preset file is already configured for UKI use."
            preset_modified="false"
        fi

        # (Re-)Build UKI files from mkinitcpio preset file (if changes were
        # applied to preset file or if UKI files are missing; if NO changes
        # were applied to preset file AND UKI files exist, stock hook has
        # likely already (re-)built UKI files, although there is no way to
        # know FOR SURE)
        echo "(Re-)Building UKI files '${uki_df_file##*/}' and '${uki_fb_file##*/}' from mkinitcpio preset file '${preset_file##*/}'..."
        if ${preset_modified} || [[ ! -f "${uki_df_file}" ]] || [[ ! -f "${uki_fb_file}" ]]; then
            preset_name="${preset_file##*/}"; preset_name="${preset_name%.*}" # 'mkinitcpio -p PRESET' expects preset file name ONLY (i.e. without path or '.preset' extension)
            if ! mkinitcpio -p "${preset_name}" || [[ ! -f "${uki_df_file}" ]] || [[ ! -f "${uki_fb_file}" ]]; then
                echo "Error: failed to (re-)build UKI files '${uki_df_file}' and '${uki_fb_file}' from mkinitcpio preset file '${preset_file}'" >&2
                result=1; continue
            fi
        else
            #echo "Stock hook should already have (re-)built UKI files '${uki_df_file##*/}' and '${uki_fb_file##*/}'."
            echo "Stock hook should already have (re-)built UKI files."
        fi

        # Check and create UEFI boot manager entries (if boot entry management
        # is enabled and if boot entries are missing; CAUTION: on some UEFIs,
        # boot entries MUST be added to BOOT ORDER to actually show up and/or
        # be selectable in UEFI GUI or when using F11/F12 to manually select
        # boot entry upon startup; working around this by adding BOTH default
        # and fallback to boot order)
        if ${UBM_ENABLED}; then
            echo "Checking UEFI boot manager entries for UKI files '${uki_df_file##*/}' and '${uki_fb_file##*/}'..."
            printf -v ubm_df_loader "${UBM_LOADER}" "${uki_df_file##*/}"
            if ubm_df_entry="$(efibootmgr | grep -iF "${ubm_df_loader}")" && [[ "${ubm_df_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                #echo "UEFI boot manager entry for default UKI file '${uki_df_file##*/}' already exists: '${ubm_df_entry}'"
                echo "Entry for default UKI file '${uki_df_file##*/}' already exists."
            else
                printf -v ubm_df_label "${UBM_DF_LABEL}" "${kernelbase}"
                echo "Creating entry for default UKI file '${uki_df_file##*/}' (label: '${ubm_df_label}', loader: '${ubm_df_loader})..."
                #if ! efibootmgr --create-only --disk "${UBM_DISK}" --part ${UBM_PART} --label "${ubm_df_label}" --loader "${ubm_df_loader}"; then # does NOT add entry to boot order
                if ! efibootmgr --create --disk "${UBM_DISK}" --part ${UBM_PART} --label "${ubm_df_label}" --loader "${ubm_df_loader}"; then       # ADDS entry to boot order
                    echo "Error: failed to create UEFI boot manager entry for default UKI file '${uki_df_file##*/}' (disk: '${UBM_DISK}', partnum: ${UBM_PART}, label: '${ubm_df_label}', loader: '${ubm_loader}')" >&2
                    result=1
                fi
            fi
            printf -v ubm_fb_loader "${UBM_LOADER}" "${uki_fb_file##*/}"
            if ubm_fb_entry="$(efibootmgr | grep -iF "${ubm_fb_loader}")" && [[ "${ubm_fb_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                #echo "UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' already exists: '${ubm_fb_entry}'"
                echo "Entry for fallback UKI file '${uki_fb_file##*/}' already exists."
            else
                printf -v ubm_fb_label "${UBM_FB_LABEL}" "${kernelbase}"
                echo "Creating entry for fallback UKI file '${uki_fb_file##*/}' (label: '${ubm_fb_label}', loader: '${ubm_fb_loader})..."
                #if ! efibootmgr --create-only --disk "${UBM_DISK}" --part ${UBM_PART} --label "${ubm_fb_label}" --loader "${ubm_fb_loader}"; then # does NOT add entry to boot order
                if ! efibootmgr --create --disk "${UBM_DISK}" --part ${UBM_PART} --label "${ubm_fb_label}" --loader "${ubm_fb_loader}"; then       # ADDS entry to boot order
                    echo "Error: failed to create UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' (disk: '${UBM_DISK}', partnum: ${UBM_PART}, label: '${ubm_fb_label}', loader: '${ubm_loader}')" >&2
                    result=1
                fi
            fi
        fi
    done

    # If mkinitcpio package is being installed/upgraded:
    # (Re-)Build all UKI files from mkinitcpio preset files
    if ${mkinitcpio_trigger}; then
        #: # nothing to do as stock hook will have done this already
        #echo "Mkinitcpio package installed/upgraded, (re-)building all UKIs:"
        echo "Mkinitcpio package installed/upgraded:"
        echo "Nothing to do, stock hook should already have (re-)built UKIs."
    fi

elif [[ "${action}" == "remove" ]]; then

    # If mkinitcpio package is being removed:
    # Remove all mkinitcpio preset files, remove all UKI files, remove all
    # associated UEFI boot manager entries (since there will be nothing left
    # after this, there is no need to process any pending kernel packages
    # triggers after this -> that is why this is placed ON TOP / FIRST)
    if ${mkinitcpio_trigger}; then
        echo "Mkinitcpio package removed, removing all existing UKIs:"

        # Gather and process mkinitcpio preset files
        echo "Fetching mkinitcpio preset files from folder '${PRESET_BASE}'..."
        readarray -t preset_files < <(find "${PRESET_BASE}" -type f -name "${PRESET_FILE/"%s"/"*"}.pacsave" | sort -V) # stock hook will already have renamed files to '.pacsave'
        #echo "Found ${#preset_files[@]} mkinitcpio preset files in folder '${PRESET_BASE}'."
        echo "Found ${#preset_files[@]} mkinitcpio preset files."
        for preset_file in "${preset_files[@]}"; do

            # Read paths of UKI files from mkinitcpio preset file
            echo "Reading UKI file paths from mkinitcpio preset file '${preset_file##*/}'..."
            if ! read_preset_var "${preset_file}" "default_uki" default_uki ||
               ! read_preset_var "${preset_file}" "fallback_uki" fallback_uki
            then
                echo "Error: failed to read UKI file paths from mkinitcpio preset file '${preset_file}'" >&2
                result=1; continue
            fi
            echo "default_uki=\"${default_uki-"<not set>"}\", fallback_uki=\"${fallback_uki-"<not set>"}\""

            # Use paths read from mkinitcpio preset file (have to rely solely
            # on these, there are no default paths to fall back to as kernel
            # package name is not available in this context)
            [[ -n "${default_uki+set}" ]]  && uki_df_file="${default_uki}"  || unset uki_df_file # for '[[ -n "${uki_df_file+set}" ]]' checks below
            [[ -n "${fallback_uki+set}" ]] && uki_fb_file="${fallback_uki}" || unset uki_fb_file # for '[[ -n "${uki_fb_file+set}" ]]' checks below

            # NOTE:
            # After this point, keep going in case of errors to remove / clean
            # up as much as possible (i.e. no 'continue', only set 'result=1')

            # Remove mkinitcpio preset file
            # NOTE:
            # DISABLING this for now, as it is generally desirable to keep
            # '.pacsave' preset files as those get REUSED when corresponding
            # kernel packages are reinstalled
            #echo "Removing mkinitcpio preset file '${preset_file}'..."
            #if [[ -f "${preset_file}" ]] && ! rm "${preset_file}"; then
            #    echo "Error: failed to remove mkinitcpio preset file '${preset_file}'" >&2
            #    result=1
            #else
            #    echo "Preset file has already been removed."
            #fi

            # Remove UKI files (stock hook should have done this already, but
            # better be safe than sorry)
            if [[ -n "${uki_df_file+set}" ]]; then
                echo "Removing default UKI file '${uki_df_file}'..."
                if [[ -f "${uki_df_file}" ]]; then
                    if ! rm "${uki_df_file}"; then
                        echo "Error: failed to remove default UKI file '${uki_df_file}'" >&2
                        result=1
                    fi
                else
                    echo "Default UKI file has already been removed."
                fi
            fi
            if [[ -n "${uki_fb_file+set}" ]]; then
                echo "Removing fallback UKI file '${uki_fb_file}'..."
                if [[ -f "${uki_fb_file}" ]]; then
                    if ! rm "${uki_fb_file}"; then
                        echo "Error: failed to remove fallback UKI file '${uki_fb_file}'" >&2
                        result=1
                    fi
                else
                    echo "Fallback UKI file has already been removed."
                fi
            fi

            # Remove UEFI boot manager entries (if boot entry management is
            # enabled)
            if ${UBM_ENABLED}; then
                if [[ -n "${uki_df_file+set}" ]]; then
                    echo "Removing UEFI boot manager entry for default UKI file '${uki_df_file##*/}'..."
                    printf -v ubm_df_loader "${UBM_LOADER}" "${uki_df_file##*/}"
                    if ubm_df_entry="$(efibootmgr | grep -iF "${ubm_df_loader}")" && [[ "${ubm_df_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                        if [[ "${ubm_df_entry}" =~ ^Boot([0-9]{4}) ]]; then # e.g. 'Boot0003* Linux HD(1,GPT,...)'
                            ubm_df_bootnum="${BASH_REMATCH[1]}"
                            if ! efibootmgr --bootnum "${ubm_df_bootnum}" --delete-bootnum; then
                                echo "Error: failed to delete UEFI boot manager entry for default UKI file '${uki_df_file##*/}' (bootnum: ${ubm_df_bootnum})" >&2
                                result=1
                            fi
                        else
                            echo "Error: failed determine bootnum of UEFI boot manager entry for default UKI file '${uki_df_file##*/}' (entry: '${ubm_df_entry}')" >&2
                            result=1
                        fi
                    else
                        #echo "Warning: no entry found for default UKI file '${uki_df_file##*/}'" >&2
                        echo "Entry for default UKI file '${uki_df_file##*/}' has already been removed."
                    fi
                fi
                if [[ -n "${uki_fb_file+set}" ]]; then
                    echo "Removing UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}'..."
                    printf -v ubm_fb_loader "${UBM_LOADER}" "${uki_fb_file##*/}"
                    if ubm_fb_entry="$(efibootmgr | grep -iF "${ubm_fb_loader}")" && [[ "${ubm_fb_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                        if [[ "${ubm_fb_entry}" =~ ^Boot([0-9]{4}) ]]; then # e.g. 'Boot0003* Linux HD(1,GPT,...)'
                            ubm_fb_bootnum="${BASH_REMATCH[1]}"
                            if ! efibootmgr --bootnum "${ubm_fb_bootnum}" --delete-bootnum; then
                                echo "Error: failed to delete UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' (bootnum: ${ubm_fb_bootnum})" >&2
                                result=1
                            fi
                        else
                            echo "Error: failed determine bootnum of UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' (entry: '${ubm_fb_entry}')" >&2
                            result=1
                        fi
                    else
                        #echo "Warning: no entry found for fallback UKI file '${uki_fb_file##*/}'" >&2
                        echo "Entry for fallback UKI file '${uki_fb_file##*/}' has already been removed."
                    fi
                fi
            fi

        done

    # For each kernel package that is being removed:
    # Remove mkinitcpio preset file, remove UKI files, remove associated UEFI
    # boot manager entries
    else
        for kernel_trigger in "${kernel_triggers[@]}"; do
            kernel_dir="${kernel_trigger%/vmlinuz}" # e.g. '/usr/lib/modules/6.1.25'
            kernel_name="${kernel_dir##*/}" # e.g. '6.1.25'
            echo "Kernel package removed, removing UKI for kernel '${kernel_name}':"

            # Gather information from kernel directory (pkgbase only; kernel-
            # base is not needed here)
            echo "Gathering information from kernel directory '${kernel_dir}'..."
            if ! read -r pkgbase < "${kernel_dir}/pkgbase"; then # e.g. 'linux61'
                echo "Error: failed to read pkgbase from '${kernel_dir}/pkgbase'" >&2
                result=1; continue
            fi
            echo "pkgbase: '${pkgbase}'"

            # NOTE:
            # After this point, keep going in case of errors to remove / clean
            # up as much as possible (i.e. no 'continue', only set 'result=1')

            # Define paths of mkinitcpio preset file and UKI files
            printf -v preset_file "${PRESET_BASE}/${PRESET_FILE}.pacsave" "${pkgbase}" # stock hook will already have renamed file to '.pacsave'
            printf -v uki_df_file "${UKI_BASE}/${UKI_DF_FILE}" "${pkgbase}" # default path, should get overridden below
            printf -v uki_fb_file "${UKI_BASE}/${UKI_FB_FILE}" "${pkgbase}" # default path, should get overridden below

            # Read paths of UKI files from mkinitcpio preset file (safer as user
            # might have modified the preset file after it had been modified
            # by this script; if this fails, fall back to the default paths that
            # were generated above)
            echo "Reading UKI file paths from mkinitcpio preset file '${preset_file##*/}'..."
            if read_preset_var "${preset_file}" "default_uki" default_uki; then
                uki_df_file="${default_uki}" # override default path
            else
                echo "Warning: failed to read path of default UKI file from mkinitcpio preset file '${preset_file}'" >&2
                echo "Warning: falling back to default path '${uki_df_file}' for default UKI file" >&2
            fi
            if read_preset_var "${preset_file}" "fallback_uki" fallback_uki; then
                uki_fb_file="${fallback_uki}" # override default path
            else
                echo "Warning: failed to read path of fallback UKI file from mkinitcpio preset file '${preset_file}'" >&2
                echo "Warning: falling back to default path '${uki_fb_file}' for fallback UKI file" >&2
            fi
            echo "default UKI file: '${uki_df_file}', fallback UKI file: '${uki_fb_file}'"

            # Remove mkinitcpio preset file
            # NOTE:
            # DISABLING this for now, as it is generally desirable to keep
            # '.pacsave' preset files as those get REUSED when corresponding
            # kernel packages are reinstalled
            #echo "Removing mkinitcpio preset file '${preset_file}'..."
            #if [[ -f "${preset_file}" ]] && ! rm "${preset_file}"; then
            #    echo "Error: failed to remove mkinitcpio preset file '${preset_file}'" >&2
            #    result=1
            #else
            #    echo "Preset file has already been removed."
            #fi

            # Remove UKI files (stock hook should have done this already, but
            # better be safe than sorry)
            echo "Removing UKI files '${uki_df_file}' and '${uki_fb_file}'..."
            if [[ -f "${uki_df_file}" ]]; then
                if ! rm "${uki_df_file}"; then
                    echo "Error: failed to remove default UKI file '${uki_df_file}'" >&2
                    result=1
                fi
            else
                echo "Default UKI file has already been removed."
            fi
            if [[ -f "${uki_fb_file}" ]]; then
                if ! rm "${uki_fb_file}"; then
                    echo "Error: failed to remove fallback UKI file '${uki_fb_file}'" >&2
                    result=1
                fi
            else
                echo "Fallback UKI file has already been removed."
            fi

            # Remove UEFI boot manager entries (if boot entry management is
            # enabled)
            if ${UBM_ENABLED}; then
                echo "Removing UEFI boot manager entries for UKI files '${uki_df_file##*/}' and '${uki_fb_file##*/}'..."
                printf -v ubm_df_loader "${UBM_LOADER}" "${uki_df_file##*/}"
                if ubm_df_entry="$(efibootmgr | grep -iF "${ubm_df_loader}")" && [[ "${ubm_df_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                    if [[ "${ubm_df_entry}" =~ ^Boot([0-9]{4}) ]]; then # e.g. 'Boot0003* Linux HD(1,GPT,...)'
                        ubm_df_bootnum="${BASH_REMATCH[1]}"
                        if ! efibootmgr --bootnum "${ubm_df_bootnum}" --delete-bootnum; then
                            echo "Error: failed to delete UEFI boot manager entry for default UKI file '${uki_df_file##*/}' (bootnum: ${ubm_df_bootnum})" >&2
                            result=1
                        fi
                    else
                        echo "Error: failed determine bootnum of UEFI boot manager entry for default UKI file '${uki_df_file##*/}' (entry: '${ubm_df_entry}')" >&2
                        result=1
                    fi
                else
                    #echo "Warning: no entry found for default UKI file '${uki_df_file##*/}'" >&2
                    echo "Entry for default UKI file '${uki_df_file##*/}' has already been removed."
                fi
                printf -v ubm_fb_loader "${UBM_LOADER}" "${uki_fb_file##*/}"
                if ubm_fb_entry="$(efibootmgr | grep -iF "${ubm_fb_loader}")" && [[ "${ubm_fb_entry}" != "" ]]; then # using option '-i' as EFI partitions are FAT32 (i.e. case-insensitive), using option '-F' as backslashes would cause issues
                    if [[ "${ubm_fb_entry}" =~ ^Boot([0-9]{4}) ]]; then # e.g. 'Boot0003* Linux HD(1,GPT,...)'
                        ubm_fb_bootnum="${BASH_REMATCH[1]}"
                        if ! efibootmgr --bootnum "${ubm_fb_bootnum}" --delete-bootnum; then
                            echo "Error: failed to delete UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' (bootnum: ${ubm_fb_bootnum})" >&2
                            result=1
                        fi
                    else
                        echo "Error: failed determine bootnum of UEFI boot manager entry for fallback UKI file '${uki_fb_file##*/}' (entry: '${ubm_fb_entry}')" >&2
                        result=1
                    fi
                else
                    #echo "Warning: no entry found for fallback UKI file '${uki_fb_file##*/}'" >&2
                    echo "Entry for fallback UKI file '${uki_fb_file##*/}' has already been removed."
                fi
            fi

        done
    fi

fi

# Exit and return result
exit ${result}
