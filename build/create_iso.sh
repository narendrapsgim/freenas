#!/bin/sh

# This script creates a bootable LiveCD iso from a nanobsd image for FreeNAS

main()
{
    # This script must be run as root
    if ! [ $(whoami) = "root" ]; then
        echo "This script must be run by root"
        exit
    fi

    cd "$(dirname "$0")/.."

    root=$(pwd)
    : ${NANO_LABEL=FreeNAS}
    : ${FREENAS_ARCH=$(uname -p)}
    case "$FREENAS_ARCH" in
    amd64)
	NANO_ARCH_HUMANIZED="x64"
	;;
    i386)
	NANO_ARCH_HUMANIZED="x86"
	;;
    *)
	NANO_ARCH_HUMANIZED=$NANO_ARCH
	;;
    esac

    export FREENAS_ARCH
    export NANO_OBJ=${root}/obj.${FREENAS_ARCH}
    REVISION="8.0.3-BETA3"
    export NANO_NAME="FreeNAS-${REVISION}-${NANO_ARCH_HUMANIZED}"
    export NANO_IMGNAME="$NANO_NAME"

    . build/functions.sh

    # Paths that may need altering on the build system
    IMGFILE="${NANO_OBJ}/$NANO_IMGNAME.Full_Install.xz"
    TEMP_IMGFILE="${NANO_OBJ}/_.imgfile" # Scratch file for image
    ETC_FILES="$root/build/files"

    # Various mount points needed to build the CD, adjust to taste
    STAGEDIR="${NANO_OBJ}/_.stage" # Scratch location for making filesystem image
    ISODIR="${NANO_OBJ}/_.isodir" # Directory ISO is rolled from
    INSTALLUFSDIR="${NANO_OBJ}/_.instufs" # Scratch mountpoint where the image will be dissected

    OUTPUT="${NANO_OBJ}/$NANO_NAME.iso" # Output file of mkisofs

    # A command forged by the gods themselves, change at your own risk
    MKISOFS_CMD="/usr/local/bin/mkisofs -R -l -ldots -allow-lowercase \
                 -allow-multidot -hide boot.catalog -o ${OUTPUT} -no-emul-boot \
                 -b boot/cdboot ${ISODIR}"
    if [ ! -f "${IMGFILE}" ]; then
        error "${0##*/}: ERROR: Can't find image file (${IMGFILE}) for ${REVISION}, punting"
    fi

    cleanup

    mkdir -p ${STAGEDIR}/dev
    mkdir -p ${ISODIR}/data

    # Create a quick and dirty nano image from the world tree
    mkdir -p ${INSTALLUFSDIR}
    tar -cf - -C ${NANO_OBJ}/_.w --exclude local . | tar -xf - -C ${INSTALLUFSDIR}
    
    # copy /rescue and /boot from the image to the iso
    tar -cf - -C ${INSTALLUFSDIR} rescue | tar -xf - -C ${STAGEDIR}
    tar -cf - -C ${INSTALLUFSDIR} boot | tar -xf - -C ${ISODIR}
    # Copy the image file to the cdrom.  Cache the compressed version to
    # make it easier to debug this and the install scripts.
    cp ${IMGFILE} ${ISODIR}/$NANO_LABEL-${NANO_ARCH_HUMANIZED}-embedded.xz

    echo "#/dev/md0 / ufs ro 0 0" > ${INSTALLUFSDIR}/etc/fstab
    (cd build/pc-sysinstall && make install DESTDIR=${INSTALLUFSDIR} NO_MAN=t)
    rm -rf ${INSTALLUFSDIR}/bin ${INSTALLUFSDIR}/sbin ${INSTALLUFSDIR}/usr/local
    rm -rf ${INSTALLUFSDIR}/usr/bin ${INSTALLUFSDIR}/usr/sbin
    ln -s ../../rescue ${INSTALLUFSDIR}/usr/bin
    ln -s ../../rescue ${INSTALLUFSDIR}/usr/sbin
    ln -s ../rescue ${INSTALLUFSDIR}/bin
    ln -s ../rescue ${INSTALLUFSDIR}/sbin
    tar -cf - -C${ETC_FILES} --exclude .svn . | tar -xf - -C ${INSTALLUFSDIR}/etc

    # Compress what's left of the image after mangling it
    makefs -b 10%  ${TEMP_IMGFILE} ${INSTALLUFSDIR}
    mkuzip -o ${ISODIR}/data/base.ufs.uzip ${TEMP_IMGFILE}

    # Magic scripts for the LiveCD
    cat > ${STAGEDIR}/baseroot.rc << 'EOF'
#!/bin/sh

# Helper routines for mounting the CD...

# Try to mount the media.  If successful, check to see if there's
# actually a baseroot image on it.  If so, leave it mounted and
# return 0.  Otherwise, return 1 with the media unmounted.
try_mount()
{
    local CD="$1" T="$2"

    [ -c ${CD} ] || return 1
    echo -n " ${CD}"
    if mount -r ${T} ${CD} ${CDROM_MP} > /dev/null 2>&1; then
        [ -f ${CDROM_MP}${BASEROOT_IMG} ] && return 0
        umount ${CDROM_MP}
    fi
    return 1
}

# Loop over the first 10 /dev/cd devices and the first 10 /dev/acd
# devices.  These devices are cd9660 formatted.
mount_cd()
{
    local CD

    for CD in /dev/cd[0-9] /dev/acd[0-9]; do
        try_mount ${CD} "-t cd9660" && return 0
    done
    return 1
}

# Loop over all the daX devices that we can find.  These devices
# are assumed to be in UFS format, so no second arg is passed
# to try_mount.
mount_memstick()
{
    local DA

    for DA in /dev/da[0-9]*; do
        try_mount ${DA} && return 0
    done
    return 1
}

PATH=/rescue

BASEROOT_MP=/baseroot
RWROOT_MP=/rwroot
CDROM_MP=/cdrom
BASEROOT_IMG=/data/base.ufs.uzip

# Re-mount root R/W, so that we can create necessary sub-directories
mount -u -w /

mkdir -p ${BASEROOT_MP}
mkdir -p ${RWROOT_MP}
mkdir -p ${CDROM_MP}

# Mount the CD device.  Since we mounted off the MD device loaded
# into memory, CAM might not have had a chance to fully discover
# a USB or SCSI cdrom drive.  Loop looking for it (also look
# for memory sticks, but that isn't fully tested yet).  Loop forever
# so you can insert a different CD if there's problems with the
# first.
echo -n "Looking for installation cdrom on "
while [ ! -f ${CDROM_MP}${BASEROOT_IMG} ]; do
    mount_cd && break
    mount_memstick && break
    sleep 1
done

# Mount future live root
mdconfig -a -t vnode -f ${CDROM_MP}${BASEROOT_IMG} -u 9
mount -r /dev/md9.uzip ${BASEROOT_MP}

# Create in-memory filesystem
mdconfig -a -t swap -s 64m -u 10
newfs /dev/md10
mount /dev/md10 ${RWROOT_MP}

# Union-mount it over live root to make it appear as R/W
mount -t unionfs ${RWROOT_MP} ${BASEROOT_MP}

# Mount devfs in live root
DEV_MP=${BASEROOT_MP}/dev
mkdir -p ${DEV_MP}
mount -t devfs devfs ${DEV_MP}

# Make whole CD content available in live root via nullfs
mkdir -p ${BASEROOT_MP}${CDROM_MP}
mount -t nullfs -o ro ${CDROM_MP} ${BASEROOT_MP}${CDROM_MP}

kenv init_shell="/bin/sh"
echo "baseroot setup done"
exit 0
EOF

    makefs -b 10% ${ISODIR}/boot/memroot.ufs ${STAGEDIR}
    gzip -9 ${ISODIR}/boot/memroot.ufs

    # More magic scripts for the LiveCD
    cat > ${ISODIR}/boot/loader.conf << EOF
#
# Boot loader file for FreeNAS.  This relies on a hacked beastie.4th.
#
autoboot_delay="2"
loader_logo="freenas"

mfsroot_load="YES"
mfsroot_type="md_image"
mfsroot_name="/boot/memroot.ufs"

init_path="/rescue/init"
init_shell="/rescue/sh"
init_script="/baseroot.rc"
init_chroot="/baseroot"
opensolaris_load="YES"
zfs_load="YES"
geom_mirror_load="YES"
EOF
    eval ${MKISOFS_CMD}
    echo "Created ${OUTPUT}"
}

cleanup()
{
    # Clean up directories used to create the liveCD
    rm -rf ${STAGEDIR}
    rm -rf ${ISODIR}
    rm -rf ${INSTALLUFSDIR}
}

main
