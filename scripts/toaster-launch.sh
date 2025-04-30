workdir="${1}"
pokydir="${2}"
builddir="${workdir}/${3}"
uselocal="${4}" # Existing DB or new one

environment="${pokydir}/oe-init-build-env"

if [ -z "${workdir}" ] || [ -z "${pokydir}" ] || [ -z "${builddir}" ]; then
    echo "Usage: $0 <workdir> <pokydir> <builddir> [LOCAL]"
    exit 1
fi

# toaster moved the toaster.sqlite db from $builddir to $toaster_dir after morty
if grep TOASTER_DIR ${pokydir}/bitbake/bin/toaster | grep -q pwd; then
    toasterdb="${builddir}/toaster.sqlite"
else
    toasterdb="${workdir}/toaster.sqlite"
fi

if  [ "${uselocal}" = "LOCAL" ]; then
    if [ ! -e ${pokydir} ]; then
        echo -e "The LOCAL mode assumes that there is a usable poky in the " \
                "workdir you passed in.\n" \
                "Current container view of workdir is ${workdir}"
        exit 1
    fi
    # in local mode we reset bootstrap to be workdir and just run what's there
fi

mkdir -p ${builddir} # if not yet existing
# don't copy over the database if it's already there or if we are in local mode
if [ ! -e "${toasterdb}" ] && [ "${uselocal}" != "LOCAL" ] && [ -f "${workdir}/toaster.sqlite" ]; then
    cp ${workdir}/toaster.sqlite ${toasterdb}

    # Replace /home/usersetup with the new workdir
    # This is required because toaster still has non-relocatable data in the
    # database we created during bootstrapping.
    sqlite3 ${toasterdb} "UPDATE bldcontrol_buildenvironment \
                          set sourcedir='${workdir}',builddir='${builddir}'"
fi

# oe environment setup
source ${environment} ${builddir}

# Run toaster and drop to an interactive shell.
# Note if the server listens on localhost in the container, it evidently
# can't be reached even with iptables without "route_localnet" enabled.
source ${pokydir}/bitbake/bin/toaster start webport="0.0.0.0:8000"

bash -i
