# PC5 Windows 작업석에서 VS Code로 DevOps 중심 작업하기

이 프로젝트의 사용자 작업석은 **물리 PC5의 Windows**로 고정한다. VS Code의 필수 접속 대상은 PC2 DevOps VM 하나이며, 모든 프로젝트 script는 그 안의 `devops` 계정으로 실행한다. PC5의 SSH private key는 PC5에만 보관한다. CP/Worker 직접 접속용 public key 배포는 장애 진단이 필요할 때만 선택적으로 수행한다.

## 1. 권장 접속 구조

```text
Windows 작업 PC
  └─ VS Code Remote-SSH / OpenSSH
       └─ DevOps VM 192.168.14.21           ← 기본 작업 위치·Git·Ansible·Kubespray
            ├─ CP1~3 192.168.14.31~33       ← 직접 접속은 진단용
            ├─ Worker1~3 192.168.14.41~43   ← 직접 접속은 진단용
            └─ LB/DB/NFS/Infra VM           ← 해당 담당자 승인 시에만 접속
```

VS Code의 기본 Remote-SSH 대상은 **DevOps VM 하나**로 둔다. 프로젝트 코드는 DevOps VM 한 곳에서만 관리하고, DevOps의 Ansible/Kubespray가 CP/Worker를 관리한다. CP/Worker에 프로젝트를 복제하거나 Ansible을 설치하지 않는다.

직접 VM 점검이 필요할 때는 Windows PC의 OpenSSH가 DevOps VM을 `ProxyJump`로 사용한다. 이 방식이면 Windows PC에서 모든 Management IP를 직접 라우팅할 필요가 없고, Network 담당자는 Windows PC→DevOps와 DevOps→대상 VM의 TCP/22만 통제하면 된다.

## 2. SSH Key 분리 원칙

| Key | Private key 보관 위치 | Public key 설치 대상 | 용도 |
|---|---|---|---|
| `neuroplan_vscode` | Windows 작업 PC만 | DevOps 및 승인된 VM | 사람·VS Code Remote-SSH |
| `neuroplan_k8s` | DevOps VM만 | CP1~3, Worker1~3 | Ansible/Kubespray 자동화 |

두 key를 혼용하지 않는다. Windows PC에 `neuroplan_k8s` private key를 복사하지 않고, DevOps VM에 `neuroplan_vscode` private key를 복사하지 않는다. Git에는 public key를 포함한 key 파일을 넣지 않는다.

## 3. 선택 사항: 직접 진단용 key 자동 배포

### PC5 Windows — key 생성 및 public key를 PC2 DevOps로 전달

PC5의 일반 PowerShell에서 실행한다. PC2 DevOps VM의 운영 계정은 `devops`다.

```powershell
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$vscodeKey = Join-Path $sshDir 'neuroplan_vscode'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $vscodeKey)) {
  ssh-keygen -t ed25519 -a 100 -f $vscodeKey `
    -C "$env:USERNAME@pc5-neuroplan-vscode"
}

ssh-keygen -lf "$vscodeKey.pub"
scp "$vscodeKey.pub" `
  devops@192.168.14.21:/tmp/neuroplan_vscode_pc5.pub
```

`neuroplan_vscode` private key는 PC5 밖으로 복사하지 않는다. PC2로 보내는 파일은 `.pub` 하나뿐이다.

### PC2 DevOps VM — 승인된 VM에 public key 일괄 배포

DevOps의 일반 운영 계정으로 프로젝트 루트에서 실행한다.

```bash
chmod +x 01-bootstrap/03-distribute-pc5-vscode-key.sh
./01-bootstrap/03-distribute-pc5-vscode-key.sh \
  /tmp/neuroplan_vscode_pc5.pub
```

스크립트 동작:

- DevOps 자신의 `authorized_keys`에는 로컬로 추가한다.
- CP1~3와 Worker1~3에는 DevOps의 `~/.ssh/neuroplan_k8s`로 접속해 추가한다.
- LB/DB/NFS/Infra는 담당자가 승인한 Linux 계정명을 역할별로 한 번씩 묻고, 기존 비밀번호 또는 이미 승인된 SSH key로 `ssh-copy-id`를 실행한다.
- 최초 접속 host fingerprint는 각 VM console 기록과 대조해야 하며 자동 승인하지 않는다.
- 일부 VM이 실패해도 나머지를 계속 처리하고 마지막에 성공·실패 목록을 출력한다.
- 재실행해도 동일 key를 중복 추가하지 않는다.

배포 대상은 `01-bootstrap/02-vscode-ssh-targets.conf`에 고정되어 있다. IP는 Management 주소만 사용하며, 스크립트는 IP·route·방화벽·`sshd_config`를 변경하지 않는다.

> 선행 조건: CP/Worker console에서 `01-managed-node-bootstrap.sh` 또는 `04-render-k8sadmin-console-command.sh`의 출력으로 `k8sadmin`과 DevOps의 `neuroplan_k8s.pub`를 먼저 준비해야 한다. `02-bootstrap-all-managed-nodes.sh`는 root SSH bootstrap이 아니라 중앙 제어 gate의 호환 alias다. LB/DB/NFS/Infra에는 담당자가 승인한 기존 로그인 계정과 TCP/22 경로가 필요하다. 인증수단 없이 중앙에서 key를 강제로 심는 것은 불가능하다.

## 4. 접속 대상 표

| SSH 별칭 | Management IP | 물리 PC | Linux 사용자 | 소유 담당 |
|---|---:|---|---|---|
| `neuroplan-lb1` | 192.168.14.11 | PC1 | `<LB_USER>` | Network/HA |
| `neuroplan-lb2` | 192.168.14.12 | PC3 | `<LB_USER>` | Network/HA |
| `neuroplan-devops` | 192.168.14.21 | PC2 | `devops` | A/DevOps |
| `neuroplan-cp1` | 192.168.14.31 | PC1 | `k8sadmin` | A |
| `neuroplan-cp2` | 192.168.14.32 | PC2 | `k8sadmin` | A |
| `neuroplan-cp3` | 192.168.14.33 | PC3 | `k8sadmin` | A |
| `neuroplan-worker1` | 192.168.14.41 | PC1 | `k8sadmin` | A |
| `neuroplan-worker2` | 192.168.14.42 | PC2 | `k8sadmin` | A |
| `neuroplan-worker3` | 192.168.14.43 | PC3 | `k8sadmin` | A |
| `neuroplan-db-primary` | 192.168.14.51 | PC4 | `<DB_USER>` | Data/DB |
| `neuroplan-db-replica` | 192.168.14.52 | PC5 | `<DB_USER>` | Data/DB |
| `neuroplan-nfs` | 192.168.14.61 | PC4 | `<STORAGE_USER>` | Storage |
| `neuroplan-infra` | 192.168.14.62 | PC5 | `<INFRA_USER>` | Network/Infra |

`<..._USER>`는 실제 계정명이 제공되지 않아 필요한 placeholder다. 각 담당자가 승인한 사용자명으로 SSH config를 수정한다. A가 다른 담당 VM에 임의로 사용자나 sudo 권한을 만들지 않는다.

## 5. STEP 1 — PC5 Windows 작업 PC 준비

관리자 PowerShell에서 OpenSSH Client 상태를 확인한다.

```powershell
Get-WindowsCapability -Online |
  Where-Object Name -Like 'OpenSSH.Client*'

Get-Command ssh
Get-Command ssh-keygen
```

`State : NotPresent`이면 관리자 PowerShell에서 설치한다.

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

VS Code와 Remote - SSH 확장을 설치한다.

```powershell
code --install-extension ms-vscode-remote.remote-ssh
```

`code` 명령이 PATH에 없다면 VS Code의 Extensions 화면에서 `Remote - SSH`를 검색해 설치한다.

검증:

```powershell
ssh -V
code --list-extensions | Select-String 'ms-vscode-remote.remote-ssh'
```

## 6. STEP 2 — Windows 전용 VS Code key 생성

일반 PowerShell에서 실행한다. `ssh-keygen`이 물으면 강한 passphrase를 입력한다.

```powershell
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

$vscodeKey = Join-Path $sshDir 'neuroplan_vscode'
ssh-keygen -t ed25519 -a 100 -f $vscodeKey `
  -C "$env:USERNAME@neuroplan-vscode"

ssh-keygen -lf "$vscodeKey.pub"
Get-Content "$vscodeKey.pub"
```

passphrase 입력을 반복하지 않으려면 관리자 PowerShell에서 Windows `ssh-agent`를 활성화한 뒤 일반 PowerShell에서 key를 등록한다.

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
$vscodeKey = Join-Path $env:USERPROFILE '.ssh\neuroplan_vscode'
ssh-add $vscodeKey
ssh-add -l
```

Private key ACL 오류가 있을 때만 다음을 사용한다.

```powershell
$vscodeKey = Join-Path $env:USERPROFILE '.ssh\neuroplan_vscode'
icacls $vscodeKey /inheritance:r
icacls $vscodeKey /grant:r "${env:USERNAME}:(R)"
```

## 7. STEP 3 — Management SSH 경로 확인

먼저 Windows PC에서 DevOps VM의 TCP/22를 확인한다.

```powershell
Test-NetConnection 192.168.14.21 -Port 22
```

`TcpTestSucceeded : False`이면 route/IP를 임의로 추가하지 않는다. Network 담당자에게 다음 정보를 전달한다.

```powershell
Get-NetIPConfiguration
route print
Test-NetConnection 192.168.14.21 -Port 22 -InformationLevel Detailed
```

Network 승인 기준:

```text
Windows 작업 PC의 승인된 source IP → DevOps 192.168.14.21:22
DevOps 192.168.14.21 → 각 VM Management IP:22
```

Windows PC에서 모든 VM이 직접 도달 가능하더라도 ProxyJump 방식을 유지하면 접속 경로와 감사 지점을 DevOps로 통일할 수 있다.

## 8. STEP 4 — SSH Server 준비 범위

CP1~3와 Worker1~3에서는 이 절을 별도로 실행하지 않는다. 유일한 root 예외인 `01-managed-node-bootstrap.sh`가 `openssh-server` 설치·활성화와 `k8sadmin` key 구성을 한 번에 처리한다.

아래 명령은 DevOps VM의 최초 준비 또는 LB/DB/NFS/Infra 담당자가 자기 소유 VM의 SSH 상태를 확인할 때만 해당 담당자가 실행한다. A 담당자가 CP/Worker에서 중복 실행하지 않는다.

```bash
sudo dnf install -y openssh-server
sudo systemctl enable --now sshd

sudo sshd -t
sudo systemctl is-active sshd
sudo systemctl is-enabled sshd
sudo ss -lntp | grep -E '[:.]22[[:space:]]'
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

마지막 fingerprint는 Windows PC의 최초 접속 화면과 대조할 수 있도록 기록한다.

firewalld는 Network 담당 영역이다. A가 `--add-service=ssh` 또는 `--add-port=22/tcp`를 임의 실행하지 않는다. Network 담당자는 실제 Management NIC의 zone과 Windows/DevOps source IP를 확인한 후 최소 source만 허용한다.

확인 명령:

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all-zones
```

## 9. STEP 5 — CP/Worker 자동화 key와 선택적 VS Code key

CP1~3와 Worker1~3에 **필수**인 key는 DevOps 자동화 public key 하나다.

- 필수 DevOps Ansible key: DevOps의 `~/.ssh/neuroplan_k8s.pub`
- 선택적 Windows 진단 key: PC5의 `%USERPROFILE%\.ssh\neuroplan_vscode.pub`

필수 key는 최초 `k8sadmin` 생성 때 각 VM console에서 `01-managed-node-bootstrap.sh`로 한 번 설치한다.

```bash
sudo ./01-managed-node-bootstrap.sh /root/neuroplan_k8s.pub
```

VS Code key 때문에 bootstrap을 다시 실행하지 않는다. PC5에서 CP/Worker를 직접 열어 진단해야 할 때만, `k8sadmin` 준비 후 PC2 DevOps에서 중앙 배포 script를 실행한다.

```bash
./01-bootstrap/03-distribute-pc5-vscode-key.sh \
  /tmp/neuroplan_vscode_pc5.pub
```

검증:

```bash
sudo ls -ld /home/k8sadmin /home/k8sadmin/.ssh
sudo ls -l /home/k8sadmin/.ssh/authorized_keys
sudo awk '{print $1, $3}' /home/k8sadmin/.ssh/authorized_keys
sudo ls -ldZ /home/k8sadmin/.ssh
sudo ls -lZ /home/k8sadmin/.ssh/authorized_keys
```

어떤 경우에도 private key를 VM으로 전달하면 안 된다. `.pub` 파일만 사용한다. 프로젝트 구축 자체에는 PC5→CP/Worker 직접 SSH가 필요하지 않다.

## 10. STEP 6 — DevOps 및 다른 담당 VM에 VS Code public key 설치

DevOps VM console에서 `devops`로 로그인한 뒤 다음을 실행한다.

```bash
install -d -m 0700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 0600 "$HOME/.ssh/authorized_keys"

IFS= read -r -p 'neuroplan_vscode.pub 한 줄을 붙여넣고 Enter: ' VSCODE_PUBLIC_KEY
case "$VSCODE_PUBLIC_KEY" in
  ssh-ed25519\ *) ;;
  *) echo '올바른 ed25519 public key가 아닙니다.' >&2; exit 1 ;;
esac

grep -Fqx -- "$VSCODE_PUBLIC_KEY" "$HOME/.ssh/authorized_keys" ||
  printf '%s\n' "$VSCODE_PUBLIC_KEY" >>"$HOME/.ssh/authorized_keys"

restorecon -RFv "$HOME/.ssh" 2>/dev/null || true
```

LB/DB/NFS/Infra VM도 각 담당자가 자신이 승인한 계정으로 동일하게 설치한다. 공용 root key 또는 팀 전체가 공유하는 private key를 만들지 않는다.

임시 password SSH가 이미 허용된 환경에서는 Windows PowerShell에서 public key를 전달할 수도 있다. 먼저 담당자의 승인을 받는다.

```powershell
$publicKey = "$env:USERPROFILE\.ssh\neuroplan_vscode.pub"
Get-Content -Raw $publicKey |
  ssh <APPROVED_USER>@192.168.14.21 `
  'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; temp=$(mktemp); tr -d "\r" >"$temp"; key=$(cat "$temp"); grep -Fqx -- "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >>~/.ssh/authorized_keys; rm -f "$temp"'
```

## 11. STEP 7 — DevOps의 ProxyJump 가능 여부 확인

DevOps VM에서 확인한다.

```bash
sudo sshd -T | grep -E '^(pubkeyauthentication|allowtcpforwarding|passwordauthentication) '
```

필수 기대값:

```text
pubkeyauthentication yes
allowtcpforwarding yes
```

key 로그인을 Windows에서 확인하기 전에는 `PasswordAuthentication no`를 적용하지 않는다. 확인 후 password 로그인을 끄려면 VM 담당자가 console 복구 경로를 확보하고 다음처럼 drop-in을 사용한다.

```bash
sudo tee /etc/ssh/sshd_config.d/60-neuroplan-key-auth.conf >/dev/null <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

sudo sshd -t
sudo systemctl reload sshd
```

기존 팀 계정이 password 로그인에 의존한다면 위 변경을 적용하지 말고 먼저 팀 합의를 받는다.

## 12. STEP 8 — Windows SSH config 작성

Windows에서 다음 파일을 연다.

```powershell
notepad "$env:USERPROFILE\.ssh\config"
```

아래 내용을 붙여넣고 `<LB_USER>`, `<DB_USER>`, `<STORAGE_USER>`, `<INFRA_USER>`를 실제 승인 계정으로 바꾼다.

```sshconfig
Host neuroplan-*
    IdentityFile ~/.ssh/neuroplan_vscode
    IdentitiesOnly yes
    PreferredAuthentications publickey
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ConnectTimeout 10

Host neuroplan-devops
    HostName 192.168.14.21
    User devops

Host neuroplan-cp1
    HostName 192.168.14.31
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-cp2
    HostName 192.168.14.32
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-cp3
    HostName 192.168.14.33
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-worker1
    HostName 192.168.14.41
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-worker2
    HostName 192.168.14.42
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-worker3
    HostName 192.168.14.43
    User k8sadmin
    ProxyJump neuroplan-devops

Host neuroplan-lb1
    HostName 192.168.14.11
    User <LB_USER>
    ProxyJump neuroplan-devops

Host neuroplan-lb2
    HostName 192.168.14.12
    User <LB_USER>
    ProxyJump neuroplan-devops

Host neuroplan-db-primary
    HostName 192.168.14.51
    User <DB_USER>
    ProxyJump neuroplan-devops

Host neuroplan-db-replica
    HostName 192.168.14.52
    User <DB_USER>
    ProxyJump neuroplan-devops

Host neuroplan-nfs
    HostName 192.168.14.61
    User <STORAGE_USER>
    ProxyJump neuroplan-devops

Host neuroplan-infra
    HostName 192.168.14.62
    User <INFRA_USER>
    ProxyJump neuroplan-devops
```

감사 경로를 PC5→DevOps→대상 VM으로 고정하기 위해 A 담당 Host의 `ProxyJump neuroplan-devops`를 제거하지 않는다.

SSH가 실제로 해석하는 설정 확인:

```powershell
ssh -G neuroplan-devops | Select-String 'hostname|user|identityfile'
ssh -G neuroplan-cp1 | Select-String 'hostname|user|proxyjump|identityfile'
```

## 13. STEP 9 — 최초 host fingerprint 승인

먼저 DevOps에 접속한다.

```powershell
ssh neuroplan-devops
```

화면에 표시되는 ED25519 fingerprint를 STEP 4에서 VM console로 확인한 값과 대조한 뒤에만 `yes`를 입력한다. `StrictHostKeyChecking no`를 설정하지 않는다.

이후 A 담당 VM을 하나씩 확인한다.

```powershell
ssh neuroplan-cp1 'hostname -s; id; ip -br -4 address'
ssh neuroplan-cp2 'hostname -s; id; ip -br -4 address'
ssh neuroplan-cp3 'hostname -s; id; ip -br -4 address'
ssh neuroplan-worker1 'hostname -s; id; ip -br -4 address'
ssh neuroplan-worker2 'hostname -s; id; ip -br -4 address'
ssh neuroplan-worker3 'hostname -s; id; ip -br -4 address'
```

한 번에 key 기반 접속을 검사한다.

```powershell
$aHosts = @(
  'neuroplan-devops',
  'neuroplan-cp1', 'neuroplan-cp2', 'neuroplan-cp3',
  'neuroplan-worker1', 'neuroplan-worker2', 'neuroplan-worker3'
)

foreach ($target in $aHosts) {
  Write-Host "===== $target ====="
  ssh -o BatchMode=yes -o ConnectTimeout=10 $target `
    'printf "host=%s user=%s\n" "$(hostname -s)" "$(id -un)"'
  if ($LASTEXITCODE -ne 0) {
    throw "SSH 검증 실패: $target"
  }
}
```

## 14. STEP 10 — VS Code에서 DevOps 프로젝트 열기

프로젝트는 DevOps VM 한 곳에 둔다. Git 원격 저장소가 있다면 DevOps에서 다음을 실행한다.

```bash
mkdir -p "$HOME/workspace"
git clone <GIT_REMOTE_URL> "$HOME/workspace/onprem-k8s"
cd "$HOME/workspace/onprem-k8s"
git status
```

Git 원격이 아직 없다면 Windows PC에서 최초 한 번 복사할 수 있다.

```powershell
ssh neuroplan-devops 'mkdir -p "$HOME/workspace"'
scp -r .\onprem-k8s neuroplan-devops:workspace/
```

VS Code 연결 순서:

1. `Ctrl+Shift+P`
2. `Remote-SSH: Connect to Host...`
3. `neuroplan-devops` 선택
4. Remote platform 질문이 나오면 `Linux` 선택
5. `File → Open Folder`
6. `/home/devops/workspace/onprem-k8s` 선택
7. VS Code 새 terminal에서 아래 확인

```bash
hostname -s
pwd
git status
ssh -i "$HOME/.ssh/neuroplan_k8s" k8sadmin@192.168.14.31 hostname -s
```

CP/Worker를 VS Code로 직접 열어야 하면 선택적 key 배포를 완료한 뒤 `Remote-SSH: Connect to Host...`에서 해당 별칭을 선택해 **새 창**으로 연다. 그 VM에서는 진단만 하고 Kubespray repository를 clone하거나 `/etc/containerd`, `/etc/kubernetes` 파일을 편집하지 않는다.

## 15. 일상 작업 흐름

```text
1. Windows에서 VS Code 실행
2. neuroplan-devops로 Remote-SSH 연결
3. ~/workspace/onprem-k8s에서 Git branch 생성·편집·검토
4. DevOps terminal에서 Ansible/Kubespray 실행
5. kubectl 및 validation script 실행
6. 변경·검증 로그 commit 또는 팀 저장소에 인계
7. CP/Worker 직접 접속은 장애 진단 시에만 사용
```

DevOps에서 사용하는 명령 예:

```bash
cd "$HOME/workspace/onprem-k8s"
source .venv/bin/activate

./02-ansible/00-ansiblectl.sh ping

kubectl get nodes -o wide
```

## 16. 문제 해결

### Windows에서 확인

```powershell
Test-NetConnection 192.168.14.21 -Port 22
ssh-add -l
ssh -G neuroplan-cp1
ssh -vvv neuroplan-cp1
```

VS Code에서는 `View → Output → Remote - SSH` 로그를 확인한다.

### VM console에서 확인 — 최초 bootstrap 또는 승인된 break-glass만

다음 절차는 중앙 SSH가 불가능한 경우에만 VM 담당자가 console에서 읽기 전용으로 수행한다. 정상 운영 중 A 담당자가 CP/Worker에 접속해 설정을 바꾸는 일상 절차가 아니다.

```bash
sudo sshd -t
sudo systemctl status sshd --no-pager
sudo journalctl -u sshd -b -n 200 --no-pager
sudo ss -lntp | grep -E '[:.]22[[:space:]]'
sudo sshd -T | grep -E '^(pubkeyauthentication|allowtcpforwarding|passwordauthentication) '

namei -l "$HOME/.ssh/authorized_keys"
ls -lZ "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
```

SELinux context나 소유권이 잘못된 경우 여기서 변경하지 않는다. read-only 결과를 담당자에게 전달하고 승인된 console 복구 작업으로 분리한다.

### 대표 오류

| 증상 | 우선 확인 |
|---|---|
| `Connection timed out` | Management route, Network ACL/firewalld source 제한, VM NIC 연결 |
| `Connection refused` | `sshd` 실행 여부와 TCP/22 listen |
| `Permission denied (publickey)` | 대상 사용자명, public key 설치, `.ssh` 0700/`authorized_keys` 0600, SELinux context |
| `Host key verification failed` | VM 재설치 여부와 console fingerprint 확인; 확인 없이 known_hosts 삭제 금지 |
| `administratively prohibited` | DevOps의 `AllowTcpForwarding yes`, ProxyJump 승인 정책 |
| VS Code Server 설치 실패 | DevOps의 Internet/DNS, `/home` 여유 공간, Remote-SSH output log |

host key가 실제 VM 재설치로 변경된 것이 확인된 경우에만 Windows에서 해당 항목을 제거한다.

```powershell
ssh-keygen -R 192.168.14.21
ssh-keygen -R neuroplan-devops
```

## 17. 완료 기준

- Windows PC의 `neuroplan_vscode` private key가 다른 VM이나 Git에 없다.
- DevOps의 `neuroplan_k8s` private key가 Windows PC나 다른 VM에 없다.
- PC5→DevOps가 `BatchMode=yes`로 password 없이 접속된다.
- DevOps→CP1~3/Worker1~3가 `neuroplan_k8s`와 `k8sadmin`으로 password 없이 접속되고 `sudo -n`이 성공한다.
- 선택적 직접 진단을 구성한 경우에만 PC5→CP/Worker도 `BatchMode=yes`로 접속된다.
- 모든 최초 접속 host fingerprint를 VM console 값과 대조했다.
- VS Code가 `neuroplan-devops`의 `~/workspace/onprem-k8s`를 연다.
- DevOps→CP/Worker Ansible ping이 모두 성공한다.
- CP/Worker에는 Ansible/Kubespray/프로젝트 clone이 없다.
- LB/DB/NFS/Infra 접속은 담당자의 사용자·sudo·방화벽 승인 후에만 활성화된다.
- IP, gateway, route는 이 SSH 준비 과정에서 변경하지 않았다.

## 공식 참고

- VS Code Remote-SSH: https://code.visualstudio.com/docs/remote/ssh
- Windows OpenSSH: https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse
