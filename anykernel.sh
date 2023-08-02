### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# begin properties
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

########## CUSTOM START ##########

BOOTMODE=false;
ps | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;
$BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;

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

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
snapshot_status=$(${bin}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	ui_print "Please reboot at least once before attempting to install!"
	if [ "$snapshot_status" == "merging" ]; then
		ui_print "If this error keeps appearing, please use the rom for a while."
	fi
	abort "Aborting..."
fi
unset snapshot_status 

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
		ui_print "- Next will backup the kernel and vendor_dlkm partitions..."

		backup_package=/sdcard/Melt-restore-kernel-$(date +"%Y%m%d-%H%M%S").zip
		${bin}/7za a -tzip -bd $backup_package \
			${home}/META-INF ${bin} ${home}/LICENSE ${home}/_restore_anykernel.sh ${split_img}/kernel ${home}/vendor_dlkm.img
		${bin}/7za rn -bd $backup_package kernel Image
		${bin}/7za rn -bd $backup_package _restore_anykernel.sh anykernel.sh
		sync

		ui_print " "
		ui_print "- The current kernel and vendor_dlkm have been backedup to:"
		ui_print "  $backup_package"
		ui_print "- If you encounter an unexpected situation,"
		ui_print "  or want to restore the stock kernel,"
		ui_print "  please flash it in TWRP or some supported apps."
		ui_print " "

		unset backup_package
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
		umount $extract_vendor_dlkm_dir

		[ "$vendor_dlkm_free_space" -gt 10240 ] || {
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."
			super_free_space=$(${bin}/lptools_static free | grep '^Free space' | awk '{print $NF}')
			[ "$super_free_space" -gt "$((10 * 1024 * 1024))" ] || {
				ui_print "! Super device does not have enough free space!"
				abort "! We have tried all known methods!"
			}

			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img
			vendor_dlkm_current_size_mb=$(du -bm ${home}/vendor_dlkm.img | awk '{print $1}')
			vendor_dlkm_target_size_mb=$((vendor_dlkm_current_size_mb + 10))
			${bin}/resize2fs ${home}/vendor_dlkm.img "${vendor_dlkm_target_size_mb}M" || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_target_size_mb}M."
			# e2fsck again
			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img

			unset super_free_space vendor_dlkm_current_size_mb vendor_dlkm_target_size_mb
		}

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	cp -f ${home}/_modules/*.ko ${extract_vendor_dlkm_modules_dir}/
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

# Patch vbmeta
for vbmeta_blk in /dev/block/bootdevice/by-name/vbmeta${slot} /dev/block/bootdevice/by-name/vbmeta_system${slot}; do
	ui_print "- Patching ${vbmeta_blk} ..."
	${bin}/vbmeta-disable-verification $vbmeta_blk || {
		ui_print "! Failed to patching ${vbmeta_blk}!"
		ui_print "- If the device won't boot after the installation,"
		ui_print "  please manually disable AVB in TWRP."
	}
done

########## CUSTOM END ##########

write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
## end boot install
