#!/bin/bash
set -Euo pipefail

# 通用错误处理函数
function error_exit() {
  echo -e "\033[31m错误: $1\033[0m" >&2
  exit 1
}

declare -A conf
declare os_type="unknown"
declare -A mirror_url=(
  [0]=ftp.debian.org
  [1]=mirrors.aliyun.com
  [2]=mirrors.163.com
  [3]=mirrors.tuna.tsinghua.edu.cn
  [4]=mirror.xtom.com.hk
  [5]=debian.csail.mit.edu
)

# 检查系统架构
function is_arch() {
  local arch
  arch=$(uname -m)

  case "$arch" in
  x86_64 | amd64)
    conf["arch"]="amd64"
    return 0
    ;;
  i386 | i686)
    conf["arch"]="i386"
    return 0
    ;;
  aarch64 | arm64)
    conf["arch"]="arm64"
    return 0
    ;;
  *)
    error_exit "不支持当前架构: ${arch}"
    ;;
  esac
}

# 获取系统版本
function get_os() {
  local issue
  local version

  # 提取公共逻辑为函数
  function check_os() {
    local content=$1
    if grep -q -E -i "ubuntu" <<< "$content"; then
      echo "ubuntu"
    elif grep -q -E -i "debian" <<< "$content"; then
      echo "debian"
    elif grep -q -E -i "centos|red hat|redhat" <<< "$content"; then
      echo "centos"
    else
      echo "unknown"
    fi
  }

  if [[ -f /etc/redhat-release ]]; then
    os_type="centos"
  elif [[ -f /etc/debian_version ]]; then
    os_type="debian"
  elif [[ -f /etc/issue ]]; then
    issue=$(cat /etc/issue)
    os_type=$(check_os "$issue")
  elif [[ -f /proc/version ]]; then
    version=$(cat /proc/version)
    os_type=$(check_os "$version")
  fi

  if [[ "$os_type" == "unknown" ]]; then
    error_exit "不支持当前系统: ${os_type}"
  else
    echo "$os_type"
  fi
}

# 网络配置
function gen_network_conf() {
  local net_interface
  local net_dns
  # 设置使用哪一个网口
  read -e -p "默认网口, 例如 eth0, 留空或 auto 将自动选择 : " -i "auto" net_interface < /dev/tty
  read -e -p "DNS : " -i "8.8.8.8 1.1.1.1" net_dns < /dev/tty

  conf["net_interface"]="$net_interface"
  conf["net_dns"]="$net_dns"

  # 获取默认网口名称
  if [[ ${conf["net_interface"]} == "auto" ]] || [[ -z ${conf["net_interface"]} ]]; then
    # 尝试通过路由获取网口名称
    conf["net_interface"]=$(ip -o -4 route get 223.5.5.5 2> /dev/null | awk '{print $5}')

    # 尝试通过默认路由获取网口名称
    if [[ -z ${conf["net_interface"]} ]]; then
      local default_route
      default_route=$(ip route | grep default)
      if [ -z "$default_route" ]; then
        error_exit "无法判断默认网口，请手动填写网口名称"
      else
        conf["net_interface"]=$(echo "$default_route" | awk '{print $5}')
      fi
    fi
  else
    if ! ip link show ${conf["net_interface"]} > /dev/null 2>&1; then
      error_exit "指定的网口 ${conf["net_interface"]} 不存在。"
    fi
  fi

  # 判断网络配置是dhcp或static
  is_dynamic=$(ip -o -4 addr show ${conf["net_interface"]} | grep "dynamic")
  if [[ "$is_dynamic" ]]; then
    conf["net_interface_type"]="dhcp"
  else
    conf["net_interface_type"]="static"
  fi

  # 获取IP地址
  conf["net_ipaddr"]=$(ip -o -4 addr show ${conf["net_interface"]} | awk '{print $4}' | cut -d'/' -f1)

  # 获取网关IP地址
  conf["net_gateway"]=$(ip route | grep default | awk '{print $3}')

  # 使用 ip 命令获取子网掩码（CIDR 格式）
  local prefix
  prefix=$(ip -o -4 addr show "${conf["net_interface"]}" 2>/dev/null \
    | grep -v secondary \
    | head -n1 \
    | grep -oP 'inet \K[\d.]+/\d+' \
    | cut -d/ -f2)

  if [[ -z "$prefix" ]]; then
    error_exit "无法获取子网掩码"
  fi

  # 转换 CIDR 前缀为点分十进制格式
  local mask=""
  local full=$((0xffffffff ^ ((1 << (32 - prefix)) - 1)))

  # 构建点分十进制格式
  for i in {3..0}; do
    local octet=$(((full >> (i * 8)) & 0xff))
    mask="$mask$octet"
    if [[ "$i" -gt 0 ]]; then
      mask="$mask."
    fi
  done

  # 设置子网掩码
  conf["net_subnet_mask"]="$mask"
}

# 获取boot相关配置
function gen_boot_conf() {
  local boot_partition

  # 获取 /boot 目录所在分区（例如 /dev/sda1）
  boot_partition=$(df /boot | awk 'NR==2 {print $1}')

  # 获取 /boot 目录所在磁盘（例如 /dev/sda or nvme0n1）
  local boot_disk
  boot_disk=$(lsblk -dno pkname "$boot_partition" 2> /dev/null)
  if [[ -n "$boot_disk" ]]; then
    conf["boot_device"]="$boot_disk"
  else
    if [[ "$boot_partition" == *"nvme"* && "$boot_partition" == *"p"* ]]; then
      conf["boot_device"]=$(echo "$boot_partition" | sed -E 's/p[0-9]+$//' | cut -d'/' -f3)
    else
      conf["boot_device"]=$(echo ${boot_partition%[0-9]*} | cut -d'/' -f3)
    fi
  fi

  # 获取分区 UUID
  conf["grub_uuid"]=$(blkid -p -s UUID ${boot_partition} | cut -d'"' -f2)

  # 检查 /boot 是否被单独挂载
  if grep -q " /boot " /proc/mounts; then
    # /boot 是单独挂载的分区
    conf["grub_boot_path"]="/"
  else
    # /boot 不是单独挂载的，而是根文件系统的一部分
    conf["grub_boot_path"]="/boot/"
  fi

}

# 生成preseed配置
function gen_preseed_conf() {
  local partition_table_type
  local boot_method
  local partman
  local network_static
  local preseed

  # 检测分区表类型
  partition_table_type=$(fdisk -l "/dev/${conf["boot_device"]}" 2> /dev/null | grep 'Disklabel type' | awk '{print $3}')

  if [[ "$partition_table_type" = "gpt" ]]; then
    read -r -d '' boot_method << 'EOF'
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-auto/choose_recipe select boot-root
d-i partman-auto/expert_recipe string                   \
    boot-root ::                                        \
        1 1 1 free                                      \
                $iflabel{ gpt }                         \
                $reusemethod{ }                         \
                method{ biosgrub }                      \
        .                                               \
        512 512 1024 free                               \
                $iflabel{ gpt }                         \
                $reusemethod{ }                         \
                method{ efi } format{ }                 \
        .                                               \
        512 512 1024 ext4                               \
                $primary{ } $bootable{ }                \
                method{ format } format{ }              \
                use_filesystem{ } filesystem{ ext4 }    \
                mountpoint{ /boot }                     \
        .                                               \
        1000 10000 1000000000 ext4                      \
                method{ format } format{ }              \
                use_filesystem{ } filesystem{ ext4 }    \
                mountpoint{ / }                         \
        .                                               \
        512 1024 200% linux-swap                        \
                method{ swap } format{ }                \
        .
EOF

  else
    read -r -d '' boot_method << 'EOF'
d-i partman-auto/choose_recipe select boot-root
d-i partman-auto/expert_recipe string                   \
    boot-root ::                                        \
        512 512 1024 ext4                               \
                $primary{ } $bootable{ }                \
                method{ format } format{ }              \
                use_filesystem{ } filesystem{ ext4 }    \
                mountpoint{ /boot }                     \
        .                                               \
        1000 10000 1000000000 ext4                      \
                method{ format } format{ }              \
                use_filesystem{ } filesystem{ ext4 }    \
                mountpoint{ / }                         \
        .                                               \
        512 1024 200% linux-swap                        \
                method{ swap } format{ }                \
        .
EOF

  fi

  read -r -d '' partman << EOF
d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
${boot_method}
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
EOF

  # 判断网络模式是否为static
  network_static=""
  if [[ ${conf["net_interface_type"]} == "static" ]]; then
    read -r -d '' network_static << EOF
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${conf["net_ipaddr"]}
d-i netcfg/get_netmask string ${conf["net_subnet_mask"]}
d-i netcfg/get_gateway string ${conf["net_gateway"]}
d-i netcfg/confirm_static boolean true
EOF
  fi

  read -r -d '' preseed << EOF
# 低内存模式
d-i lowmem/low boolean true
d-i lowmem/insufficient boolean true

# 语言和地区
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/country string US
d-i debian-installer/language string en
d-i keyboard-configuration/xkb-keymap select us

# 设置时区
d-i clock-setup/utc boolean true
d-i time/zone string Asia/Hong_Kong

# 网络设置
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_nameservers string ${conf["net_dns"]}
${network_static}

# 网络控制台模块
#d-i anna/choose_modules string network-console
#d-i preseed/early_command string anna-install network-console
# 设置网络控制台的密码，默认用户名： installer
#d-i network-console/password password 123456
#d-i network-console/password-again password 123456

# 设置镜像源
d-i mirror/country string manual
d-i mirror/http/hostname string ${conf["mirror_domain"]}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# 分区设置
# 不再指定设备名，采用默认搜索机制
# 如果指定设备名，某些服务商的奇怪设置可能会导致无法找到设备，导致出现以下问题：
# No root file system
# No root file system is defined.
# Please correct this from the partitioning menu.

# 特别情况，如果你的机器有多个磁盘，并系统盘不是第一顺位盘则可以指定

# /dev/xxx
#d-i partman-auto/disk string /dev/${conf["boot_device"]}

${partman}

# 设置root用户密码
d-i passwd/root-login boolean true
d-i passwd/root-password-crypted password ${conf["root_pass"]}
d-i passwd/make-user boolean false

# 配置apt和软件选择
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server build-essential
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false

popularity-contest popularity-contest/participate boolean false

# 安装GRUB引导加载程序
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string default

# 安装完成后执行命令
d-i preseed/late_command string \
  in-target sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config ; \
  in-target systemctl restart ssh.service

# 重启通知
d-i finish-install/reboot_in_progress note
EOF

  local temp_dir
  # 创建一个临时目录来处理initrd
  temp_dir=$(mktemp -d)
  # 确保在脚本退出时（无论成功或失败）都清理临时目录
  trap 'rm -rf -- "$temp_dir"' EXIT

  cd "$temp_dir" || error_exit "无法进入临时目录 $temp_dir"

  echo
  echo
  echo '解包中...'
  gzip -dc /root/initrd.gz | cpio -idmu && echo '解包完成' && rm -fr /root/initrd.gz
  echo
  echo '生成 pressed 配置并写入'
  echo "$preseed" > preseed.cfg
  echo
  echo '重新归档压缩中...'
  find . | cpio -H newc --create | gzip -9 > "${conf["mirror_dir"]}"/initrd.gz && echo '归档压缩完成'

  # 返回原始目录并解除trap
  cd - > /dev/null
  trap - EXIT
  rm -rf -- "$temp_dir"
}

# 设置镜像
function set_mirror() {
  local index=0

  echo
  echo
  echo '========选择镜像源========='
  echo
  echo "0. 默认 官方源"
  echo "1. 中国 阿里云"
  echo "2. 中国 网易"
  echo "3. 中国 清华大学"
  echo "4. 香港 Xtom 注：中国无法访问"
  echo "5. 美国 麻省理工"
  echo

  read -e -p "选择镜像源 [0-5] : " -i "0" index < /dev/tty

  conf["mirror_domain"]=${mirror_url[$index]}

  conf["mirror_dir"]="/boot/debian-netboot-install"
  rm -fr ${conf["mirror_dir"]} && mkdir -p ${conf["mirror_dir"]}

  local down_url="https://${conf["mirror_domain"]}/debian/dists/bookworm/main/installer-${conf["arch"]}/current/images/netboot/debian-installer/${conf["arch"]}"

  wget -O /root/initrd.gz "${down_url}/initrd.gz" || error_exit "下载 initrd.gz 失败，请重试或更换镜像源"
  wget -O "${conf["mirror_dir"]}"/linux "${down_url}/linux" || error_exit "下载 linux 失败，请重试或更换镜像源"
}

function gen_root_pass() {

  function gen_func1() {
    echo '设置ROOT密码'
    echo '屏幕不会显示输入内容，输入后回车再重复一次'
    while true; do
      local hash
      hash=$(openssl passwd -6 2> /dev/null)
      if [[ "$hash" != "<NULL>" && -n "$hash" ]]; then
        conf["root_pass"]="$hash"
        echo '密码设置成功'
        return 0
      else
        echo -e "\n两次输入的密码不一致，重新输入"
      fi
    done
  }

  function gen_func2() {
    echo '设置ROOT密码'
    echo '屏幕不会显示输入内容，输入后回车再重复一次'
    while true; do
      local password1 password2 hash
      read -s -p "Password: " password1 < /dev/tty
      echo
      read -s -p "Verifying - Password: " password2 < /dev/tty
      echo

      if [[ "$password1" == "$password2" ]]; then
        hash=$(python3 -c '
import crypt, sys
pwd = sys.stdin.readline().rstrip("\n")
print(crypt.crypt(pwd, crypt.mksalt(crypt.METHOD_SHA512)))
' <<< "$password1" 2> /dev/null || python2 -c '
# -*- coding: utf-8 -*-
import crypt, sys, random, string
pwd = sys.stdin.readline().rstrip("\n")
salt_chars = string.ascii_letters + string.digits + "./"
random_salt = "".join(random.choice(salt_chars) for _ in range(8))
salt = "$6$" + random_salt
print crypt.crypt(pwd, salt)
' <<< "$password1")

        if [[ -n "$hash" ]]; then
          conf["root_pass"]="$hash"
          echo "密码设置成功"
          unset password1 password2
          return 0
        else
          echo -e "\n生成哈希失败，请重试"
          unset password1 password2
          continue
        fi
      else
        echo -e "\n两次输入的密码不一致，重新输入"
      fi
    done
  }

  # OpenSSL版本检测
  local openssl_version
  openssl_version=$(openssl version 2> /dev/null | awk '{split($2, a, "."); print a[1]}')

  # 版本比较逻辑
  if [[ "$openssl_version" -ge 3 ]]; then
    gen_func1
  else
    gen_func2
  fi
}

# 更新grub
function up_grub() {

  # 自定义启动项
  cat << EOF > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 \$0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
menuentry 'debian-netboot-install' {
search --fs-uuid --set=root ${conf["grub_uuid"]}
linux ${conf["grub_boot_path"]}debian-netboot-install/linux auto=true priority=critical root=/dev/ram0
initrd ${conf["grub_boot_path"]}debian-netboot-install/initrd.gz
}
EOF

  # 设置GRUB启动项等待时间为0
  if grep -q "^GRUB_TIMEOUT=" /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
  else
    echo "GRUB_TIMEOUT=0" >> /etc/default/grub
  fi

  # 更新grub设置和选择下一次的启动项
  if [[ "${os_type}" == "centos" ]]; then
    grub2-mkconfig -o /etc/grub2.cfg
    grub2-reboot "debian-netboot-install"
  elif [[ "${os_type}" == "debian" || "${os_type}" == "ubuntu" ]]; then
    update-grub
    grub-reboot "debian-netboot-install"
  fi
}

#function set_console_pass() {
#  read -e -p "临时SSH控制台密码 : " netconsole_pass </dev/tty
#  if [[ -z "$netconsole_pass" || ${#netconsole_pass} -lt 6 ]]; then
#    echo "密码为空或小于6位数…"
#    set_console_pass
#  fi
#}
#set_console_pass

# 启动函数
function start() {
  clear

  if [[ $EUID -ne 0 ]]; then
    error_exit "此脚本必须以 root 权限运行"
  fi

  echo
  echo
  echo '==========================='
  echo '====Debian12 自动安装脚本===='
  echo '==========================='
  echo
  echo

  is_arch

  local os_type
  os_type=$(get_os)

  case "$os_type" in
  debian | ubuntu)
    apt install -y wget
    ;;
  centos)
    yum install -y wget
    ;;
  esac

  echo

  gen_network_conf

  gen_boot_conf

  echo
  gen_root_pass

  set_mirror

  gen_preseed_conf

  up_grub

  clear
  echo
  echo
  echo "========================================="
  echo "配置完成，等待重启后进行自动安装"
  echo "========================================="
  echo
  echo "自行输入：reboot 进行重启，建议等待15-30分钟后尝试连接。"
  echo
  echo "注意：带宽较慢或性能较差的机器可能需要更长时间！"
  echo
  echo "如果要查看安装进度请连接VNC"
  echo
  echo "某些环境不一定能完全自动安装成功，如果长时间未能登录SSH，自行前往VNC控制台进行查看或操作"
  echo
  echo
  echo "SSH端口：22"
  echo
  echo
}

start
