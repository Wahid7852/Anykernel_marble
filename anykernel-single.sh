### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Melt Kernel by Pzqqt
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install

## boot shell variables
block=boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

dump_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

########## FLASH BOOT & VENDOR_DLKM START ##########

BOOTMODE=false;
ps | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;
$BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;

KEYCODE_UP=42
KEYCODE_DOWN=41

no_needed_kos='
atmel_mxt_ts.ko
cameralog.ko
coresight-csr.ko
coresight-cti.ko
coresight-dummy.ko
coresight-funnel.ko
coresight-hwevent.ko
coresight-remote-etm.ko
coresight-replicator.ko
coresight-stm.ko
coresight-tgu.ko
coresight-tmc.ko
coresight-tpda.ko
coresight-tpdm.ko
coresight.ko
cs35l41_dlkm.ko
f_fs_ipc_log.ko
focaltech_fts.ko
icnss2.ko
nt36xxx-i2c.ko
nt36xxx-spi.ko
qca_cld3_qca6750.ko
qcom-cpufreq-hw-debug.ko
qcom_iommu_debug.ko
qti_battery_debug.ko
rdbg.ko
spmi-glink-debug.ko
spmi-pmic-arb-debug.ko
stm_console.ko
stm_core.ko
stm_ftrace.ko
stm_p_basic.ko
stm_p_ost.ko
synaptics_dsx.ko
'

extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${bin}/extract.erofs -i $img_file -x -T8 -o $out_dir &> /dev/null
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2

	local partition_name=$(basename $work_dir)

	${bin}/mkfs.erofs \
		--mount-point /${partition_name} \
		--fs-config-file ${work_dir}/../config/${partition_name}_fs_config \
		--file-contexts  ${work_dir}/../config/${partition_name}_file_contexts \
		-z lz4hc \
		$out_file $work_dir
}

is_mounted() { mount | grep -q " $1 "; }

sha1() { ${bin}/magiskboot sha1 "$1"; }

get_keycheck_result() {
	# Default behavior:
	# - press Vol+: return true (0)
	# - press Vol-: return false (1)

	# The first execution responds to the button press event,
	# the second execution responds to the button release event.
	${bin}/keycheck; ${bin}/keycheck
	local r_keycode=$?
	case $r_keycode in
		"$KEYCODE_UP") return 0;;
		"$KEYCODE_DOWN") return 1;;
		*) abort "! Unknown keycode: $r_keycode"
	esac
}

keycode_select() {
	local prompt_text=$1
	local r_keycode

	ui_print " "
	ui_print "# $prompt_text"
	ui_print "#"
	ui_print "# Vol+ = Yes, Vol- = No."
	ui_print "# Please press the key..."
	get_keycheck_result
	r_keycode=$?
	ui_print "#"
	if [ "$r_keycode" -eq "0" ]; then
		ui_print "- You chose Yes."
	else
		ui_print "- You chose No."
	fi
	ui_print " "
	return $r_keycode
}

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${bin}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if $BOOTMODE; then
		ui_print "If you are installing the kernel in an app, try using another app."
		ui_print "Recommend KernelFlasher:"
		ui_print "  https://github.com/capntrips/KernelFlasher/releases"
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
snapshot_status=$(${bin}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
ui_print "Current snapshot state: $snapshot_status"
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	if [ "$snapshot_status" == "merging" ]; then
		ui_print "Please use the rom for a while to wait for"
		ui_print "the system to complete the snapshot merge."
		ui_print "It's also possible to use the \"Merge Snapshots\" feature"
		ui_print "in TWRP's Advanced menu to instantly merge snapshots."
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
unset rc snapshot_status

# Check super device size
block_device_size=$(blockdev --getsize64 /dev/block/by-name/super) || \
	abort "! Failed to get super block device size!"
ui_print "Super block device size: $block_device_size"
[ "$block_device_size" == "9663676416" ] || \
	abort "! Super block device size mismatch!"
unset block_device_size

# Check vendor_dlkm partition status
[ -d /vendor_dlkm ] || mkdir /vendor_dlkm
is_mounted /vendor_dlkm || \
	mount /vendor_dlkm -o ro || mount /dev/block/mapper/vendor_dlkm${slot} /vendor_dlkm -o ro || \
		abort "! Failed to mount /vendor_dlkm"

strings ${home}/Image 2>/dev/null | grep -E -m1 'Linux version.*#' > ${home}/vertmp

skip_update_flag=false
do_backup_flag=false
if [ -f /vendor_dlkm/lib/modules/vertmp ]; then
	[ "$(cat /vendor_dlkm/lib/modules/vertmp)" == "$(cat ${home}/vertmp)" ] && skip_update_flag=true
else
	do_backup_flag=true
fi
umount /vendor_dlkm

if $skip_update_flag; then
	case $(basename "$ZIPFILE" .zip) in
		*-force) skip_update_flag=false;;
	esac
fi

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

ui_print " "
if $skip_update_flag; then
	ui_print "- No need to update /vendor_dlkm partition."
else
	# Dump vendor_dlkm partition image
	dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img

	# Backup kernel and vendor_dlkm image
	if $do_backup_flag; then
		ui_print "- It looks like you are installing Melt Kernel for the first time."

		keycode_select "Backup the current kernel?" && {
			ui_print "- Backing up kernel, vendor_boot, and vendor_dlkm partition..."

			build_prop=/system/build.prop
			[ -d /system_root/system ] && build_prop=/system_root/$build_prop
			backup_package=/sdcard/Melt-restore-kernel-$(file_getprop $build_prop ro.build.version.incremental)-$(date +"%Y%m%d-%H%M%S").zip

			dd if=/dev/block/bootdevice/by-name/vendor_boot${slot} of=${home}/vendor_boot.img

			${bin}/7za a -tzip -bd $backup_package \
				${home}/META-INF ${bin} ${home}/LICENSE ${home}/_restore_anykernel.sh \
				${split_img}/kernel ${home}/vendor_dlkm.img ${home}/vendor_boot.img
			${bin}/7za rn -bd $backup_package kernel Image
			${bin}/7za rn -bd $backup_package _restore_anykernel.sh anykernel.sh
			sync

			ui_print " "
			ui_print "- The current kernel, vendor_boot, vendor_dlkm have been backedup to:"
			ui_print "  $backup_package"
			ui_print "- If you encounter an unexpected situation,"
			ui_print "  or want to restore the stock kernel,"
			ui_print "  please flash it in TWRP or some supported apps."
			ui_print " "
			rm ${home}/vendor_boot.img
			touch ${home}/do_backup_flag

			unset build_prop backup_package
		}
	fi

	ui_print "- Unpacking /vendor_dlkm partition..."
	extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm
	mkdir -p $extract_vendor_dlkm_dir
	vendor_dlkm_is_ext4=false
	extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true
	sync

	if $vendor_dlkm_is_ext4; then
		ui_print "- /vendor_dlkm partition seems to be in ext4 file system."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o ro -t ext4 || \
			abort "! Unsupported file system!"
		vendor_dlkm_free_space=$(df -k | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $4}')
		ui_print "- /vendor_dlkm partition free space: $vendor_dlkm_free_space"
		umount $extract_vendor_dlkm_dir

		[ "$vendor_dlkm_free_space" -gt 10240 ] || {
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."

			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img
			vendor_dlkm_current_size_mb=$(du -bm ${home}/vendor_dlkm.img | awk '{print $1}')
			vendor_dlkm_target_size_mb=$((vendor_dlkm_current_size_mb + 10))
			${bin}/resize2fs ${home}/vendor_dlkm.img "${vendor_dlkm_target_size_mb}M" || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_target_size_mb}M."
			# e2fsck again
			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img

			unset vendor_dlkm_current_size_mb vendor_dlkm_target_size_mb
		}

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	if [ "$(sha1 ${extract_vendor_dlkm_modules_dir}/qti_battery_charger.ko)" == "b5aa013e06e545df50030ec7b03216f41306f4d4" ]; then
		rm ${home}/_vendor_dlkm_modules/qti_battery_charger.ko
	fi
	cp -f ${home}/_vendor_dlkm_modules/*.ko ${extract_vendor_dlkm_modules_dir}/
	blocklist_expr=$(echo $no_needed_kos | awk '{ printf "-vE \^\("; for (i = 1; i <= NF; i++) { if (i == NF) printf $i; else printf $i "|"; }; printf "\)" }')
	mv -f ${extract_vendor_dlkm_modules_dir}/modules.load ${extract_vendor_dlkm_modules_dir}/modules.load.old
	cat ${extract_vendor_dlkm_modules_dir}/modules.load.old | grep $blocklist_expr > ${extract_vendor_dlkm_modules_dir}/modules.load
	rm -f ${extract_vendor_dlkm_modules_dir}/modules.load.old
	for f in $no_needed_kos; do
		rm -f ${extract_vendor_dlkm_modules_dir}/$f
	done
	cp -f ${home}/vertmp ${extract_vendor_dlkm_modules_dir}/vertmp
	sync

	if $vendor_dlkm_is_ext4; then
		set_perm 0 0 0644 ${extract_vendor_dlkm_modules_dir}/vertmp
		chcon u:object_r:vendor_file:s0 ${extract_vendor_dlkm_modules_dir}/vertmp
		umount $extract_vendor_dlkm_dir
	else
		cat ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config | grep -q 'lib/modules/vertmp' || \
			echo 'vendor_dlkm/lib/modules/vertmp 0 0 0644' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config
		cat ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts | grep -q 'lib/modules/vertmp' || \
			echo '/vendor_dlkm/lib/modules/vertmp u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts
		ui_print "- Repacking /vendor_dlkm image..."
		rm -f ${home}/vendor_dlkm.img
		mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || \
			abort "! Failed to repack the vendor_dlkm image!"
		rm -rf ${extract_vendor_dlkm_dir}
	fi

	unset vendor_dlkm_is_ext4 vendor_dlkm_free_space extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir blocklist_expr
fi

unset no_needed_kos skip_update_flag do_backup_flag

write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk

########## FLASH BOOT & VENDOR_DLKM END ##########

# Remove files no longer needed to avoid flashing again.
rm ${home}/Image
rm ${home}/boot.img
rm ${home}/boot-new.img
rm ${home}/vendor_dlkm.img

########## FLASH VENDOR_BOOT START ##########

## vendor_boot shell variables
block=vendor_boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

# reset for vendor_boot patching
reset_ak

# Put the module files in the vendor_boot partition to be replaced in ${home}/ramdisk/lib/modules,
# and AK3 will automatically process them.
mkdir -p ${home}/ramdisk/lib/modules
cp ${home}/_vendor_boot_modules/*.ko ${home}/ramdisk/lib/modules/

# vendor_boot install
dump_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk

########## FLASH VENDOR_BOOT END ##########

# Patch vbmeta
ui_print " "
for vbmeta_blk in /dev/block/bootdevice/by-name/vbmeta${slot} /dev/block/bootdevice/by-name/vbmeta_system${slot}; do
	ui_print "- Patching ${vbmeta_blk} ..."
	${bin}/vbmeta-disable-verification $vbmeta_blk || {
		ui_print "! Failed to patching ${vbmeta_blk}!"
		ui_print "- If the device won't boot after the installation,"
		ui_print "  please manually disable AVB in TWRP."
	}
done

## end boot install