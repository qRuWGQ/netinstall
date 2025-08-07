# Linux-Debian-Netboot-Auto-Install

一键网络重装 Debian 12 纯净系统

## 实现方法  

使用 `Debian` 的 `netboot` 安装方式，并通过 `preseed.cfg` 完成系统的安装和配置。

---

### 脚本运行要求
>
> 系统: `Debian/Ubuntu` ｜ `Centos/Redhat`  
> 架构: `amd64` | `arm64` | `i386`

---

### 功能一览

* 自动识别引导方式和分区表类型  
* APT镜像源选择，系统镜像也是从选择的源下载  
* 自动识别默认网口或手动指定，自动识别网络类型是DHCP或static  
* ROOT密码设定
* 默认使用的是当前系统所在的磁盘进行自动分区
* 目前安装的系统是 `Debian 12`

---

### 目前测试过的平台

| 平台        | 引导方式 | 分区表类型 | 说明 |
|-----------|------|-------|----|
| Dogyun    | BIOS | MBR   | 支持 |
| 阿里云ECS服务器 | BIOS | MBR   | 支持 |
| 阿里云轻量云服务器 | BIOS | MBR   | 支持 |
| 阿里云轻量云服务器 | BIOS | GPT   | 支持 |
| Vultr     | UEFI | GPT   | 支持 |
| LocVPS    | BIOS | MBR   | 支持 |
| DMIT      | BIOS | MBR   | 支持 |

---

### 特别事项

* 阿里云的机器建议先在控制台重装为 Debian 10 (BIOS引导模式) 或 Centos 7 再运行脚本！不知道什么原因高于这两个版本，多次测试都是无法识别到硬盘或者无法进行分区。
* 某些环境不一定能完全自动安装成功，如果长时间未能登录SSH，自行前往VNC控制台进行查看或操作  

---

## 执行

```shell
curl https://raw.githubusercontent.com/qRuWGQ/Linux-Debian-Netboot-Auto-Install/main/install.sh | bash
```
