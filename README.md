# VMware On-Premise Kubernetes HA 구축 프로젝트

CentOS Stream 9 VM 6대에 **Kubespray v2.31.0 + Ansible**로 self-managed Kubernetes HA 클러스터를 구축하는 실행 저장소다. 모든 명령은 별도 표시가 없으면 **PC2 DevOps VM의 `devops` 계정**에서 프로젝트 루트를 현재 디렉터리로 두고 실행한다.

> 이 저장소는 기존 NIC/IP/gateway/route를 변경하지 않는다. CP/Worker 역할을 합치지 않으며 DevOps VM을 클러스터에 넣지 않는다.

## 실행 위치 고정 원칙

초기 `k8sadmin` 생성만 CP1~3와 Worker1~3의 VMware console에서 `root`로 한 번 실행한다. 중앙 NTP는 DevOps VM에서 `08-configure-all-vm-ntp.sh`로 일괄 설정하며, Infra만 복구할 때 Infra/Network 담당자가 `07-configure-infra-ntp.sh`를 `root`로 실행한다. 그 외 Ansible, Kubespray, Registry, add-on, validation, troubleshooting 명령은 모두 PC2 DevOps VM의 `devops` 계정에서 실행한다. 원격 자동화 계정은 여섯 노드 공통 `k8sadmin`이며, 계정 password를 설정했더라도 자동화에서는 사용하지 않고 `~/.ssh/neuroplan_k8s`와 passwordless sudo만 사용한다.

LB/DB/NFS/Infra는 Kubespray inventory와 `k8sadmin` 생성 범위가 아니다. 전체 기준과 금지 사항은 [00-docs/07-devops-execution-policy.md](00-docs/07-devops-execution-policy.md)를 따른다.

## 1. 설계 요약

- CP1~3: 독립 Control Plane + stacked etcd 3멤버
- Worker1~3: 독립 Worker
- SSH/Ansible: Management `192.168.14.x`
- Kubernetes/etcd/Calico: Internal `192.168.34.x`
- API endpoint: 외부 HAProxy/Keepalived VIP `https://192.168.34.100:6443`
- Service endpoint: `192.168.24.100:443 -> Worker .34.41~43:30443`
- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/12`
- DevOps Registry: `192.168.34.21:5000`

세부 주소는 [00-docs/00-architecture.md](00-docs/00-architecture.md), 포트는 [00-docs/03-port-matrix.md](00-docs/03-port-matrix.md), 모든 파일의 목적은 [00-docs/05-file-catalog.md](00-docs/05-file-catalog.md)를 따른다. 한 대의 Windows PC에서 VS Code로 접속하는 사전 절차는 [00-docs/06-vscode-ssh-guide.md](00-docs/06-vscode-ssh-guide.md)에 있다.

Kubernetes 내부 DNS domain은 기존 `neuroplan.local`을 유지하고, 일반 VM과
애플리케이션의 Infra BIND domain `nplan.local`과 분리한다. Kubernetes API는
DNS에 의존하지 않는 고정 VIP를 canonical endpoint로 사용한다. 결정 기록은
[00-docs/09-api-fqdn-migration.md](00-docs/09-api-fqdn-migration.md)를 따른다.

## 2. Kubespray 담당 영역

Kubespray가 Kubernetes/kubelet/kubeadm/kubectl, stacked etcd, containerd, Calico, CoreDNS, Pod/Service CIDR, Node IP, swap, kernel/sysctl, CP/Worker의 NTP/timezone, SELinux 사전 정책, Secret-at-rest 암호화, Metrics Server와 Gateway API CRD를 관리한다. `08-configure-all-vm-ntp.sh`가 먼저 동일한 중앙 NTP 토폴로지를 전 VM에 적용하고, 이후 Kubespray가 CP/Worker의 같은 설정을 유지한다.

Kubespray 소스는 수정하지 않는다. `03-kubespray/inventory/mycluster`의 중앙 inventory만 Git으로 관리하고, CP/Worker에는 Kubespray 또는 Ansible을 설치하지 않는다.

## 3. 직접 구현 영역

- 최초 SSH/Python/sudo bootstrap
- hostname, `/etc/hosts`, 관리 패키지
- DevOps VM의 Docker Hub 인증, Podman Quadlet Registry와 image 동기화
- Helm client와 NGINX Gateway Fabric
- 한 개의 Gateway, HTTPRoute, 검증 workload/HPA/PDB
- 자동 검증, 로그 수집, 재시도, reset guard, etcd snapshot

상세 경계는 [00-docs/01-responsibility-boundary.md](00-docs/01-responsibility-boundary.md)에 있다.

## 4. 버전 결정

Kubespray `v2.31.0`의 실제 checksum과 defaults를 기준으로 다음 조합을 사용한다.

| 구성요소 | 적용 |
|---|---:|
| Kubespray | v2.31.0 / `1c9add48975060f45396b34d8e022c30d7f80dab` |
| Kubernetes | 1.35.4 |
| containerd | 2.2.3 |
| Calico | 3.31.5 |
| Metrics Server | 0.8.1 |
| Gateway API | 1.5.1 standard |
| NGINX Gateway Fabric | 2.6.7 |

기획 목표의 Kubernetes `1.35.6`과 Calico `3.32.x`는 이 release에 checksum이 없어 강제하지 않는다. containerd `2.1.7`은 checksum이 있지만 release 기본값 `2.2.3`을 안전 기준으로 선택했다. [00-docs/02-version-matrix.md](00-docs/02-version-matrix.md)와 `03-verify-release.sh`에 결정 근거와 자동 검사를 남겼다.

NGF 2.6.7은 Gateway API 1.5.1과 Kubernetes 1.31+ 조합을 공식 지원한다. NGF 설치 단계는 Kubespray가 설치한 Gateway API CRD를 검사만 하며 재설치하지 않는다.

## 5. 전체 디렉터리 Tree

```text
onprem-k8s/
├── README.md
├── .gitignore
├── 00-set-executable-permissions.sh
├── 00-docs/
│   ├── 00-architecture.md
│   ├── 01-responsibility-boundary.md
│   ├── 02-version-matrix.md
│   ├── 03-port-matrix.md
│   ├── 04-handoff-checklist.md
│   ├── 05-file-catalog.md
│   ├── 06-vscode-ssh-guide.md
│   ├── 07-devops-execution-policy.md
│   ├── 08-firewalld-calico-compatibility.md
│   └── 09-api-fqdn-migration.md
├── 01-bootstrap/
│   ├── 00-devops-bootstrap.sh
│   ├── 01-managed-node-bootstrap.sh
│   ├── 02-bootstrap-all-managed-nodes.sh
│   ├── 02-vscode-ssh-targets.conf
│   ├── 03-distribute-pc5-vscode-key.sh
│   ├── 04-render-k8sadmin-console-command.sh
│   ├── 05-verify-devops-control.sh
│   ├── 06-repair-devops-public-key.sh
│   ├── 07-configure-infra-ntp.sh
│   └── 08-configure-all-vm-ntp.sh
├── 02-ansible/
│   ├── 00-ansiblectl.sh
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.yaml
│   │   └── group_vars/all.yml
│   ├── templates/
│   │   └── hosts.j2
│   ├── tasks/
│   │   └── validate-host-records.yml
│   └── playbooks/
│       ├── 04-preflight.yml
│       ├── 05-os-baseline.yml
│       └── 06-validate-baseline.yml
├── 03-kubespray/
│   ├── 02-install-kubespray.sh
│   ├── 03-verify-release.sh
│   ├── ansible.cfg                       # strict known_hosts/key 정책
│   ├── 10-preflight.sh
│   ├── 11-deploy-cluster.sh
│   ├── 12-install-devops-client.sh
│   ├── 13-migrate-api-fqdn.sh
│   ├── 14-pin-api-vip-endpoint.sh
│   ├── vendor/kubespray/                 # 생성, Git 제외
│   └── inventory/mycluster/
│       ├── hosts.yaml
│       ├── artifacts/                    # 생성, Git 제외
│       ├── credentials/                  # 생성, 민감정보, Git 제외
│       └── group_vars/
│           ├── etcd.yml
│           ├── all/
│           │   ├── all.yml
│           │   └── containerd.yml
│           └── k8s_cluster/
│               ├── addons.yml
│               ├── k8s-cluster.yml
│               └── k8s-net-calico.yml
├── 04-registry/
│   ├── 06-configure-dockerhub-auth.sh
│   ├── 07-install-registry.yml
│   ├── 08-images.txt
│   ├── 08-sync-images.sh
│   ├── 09-list-images.sh
│   ├── 09-registryctl.sh
│   ├── 09-verify-registry.sh
│   └── templates/
│       ├── 07-onprem-registry.container.j2
│       └── 07-050-onprem-registry.conf.j2
├── 05-k8s-addons/
│   ├── 12-create-dockerhub-pull-secret.sh
│   ├── 13-install-helm.sh
│   ├── 14-install-ngf.sh
│   ├── 14-ngf-values.yaml
│   ├── 15-namespace.yaml
│   ├── 16-test-workload.yaml
│   ├── 17-pdb.yaml
│   ├── 18-hpa.yaml
│   ├── 19-create-test-tls.sh
│   ├── 20-gateway.yaml
│   ├── 21-httproute.yaml
│   └── 22-apply-platform-test.sh
├── 06-validation/
│   ├── 23-verify-cluster.sh
│   ├── 24-verify-network.sh
│   ├── 25-test-self-healing.sh
│   ├── 26-hpa-load-job.yaml
│   ├── 26-test-hpa.sh
│   ├── 27-verify-pdb.sh
│   ├── 28-verify-ngf.sh
│   ├── 29-verify-ha-readonly.sh
│   └── 30-run-all.sh
├── 07-troubleshooting/
│   ├── 31-collect-diagnostics.sh
│   ├── 32-check-node.sh
│   ├── 33-etcd-snapshot.sh
│   ├── 34-retry-node.sh
│   ├── 35-reset-cluster.sh
│   ├── 36-recovery.md
│   ├── 37-cleanup-validation.sh
│   └── 38-manage-k8s-firewalld.sh
└── nodes/
    ├── cp1/00-node-facts.md
    ├── cp2/00-node-facts.md
    ├── cp3/00-node-facts.md
    ├── worker1/00-node-facts.md
    ├── worker2/00-node-facts.md
    └── worker3/00-node-facts.md
```

## 6. 사전 승인 게이트

실행 전에 다음을 확인한다.

- [ ] 기존 고정 IP와 default route 하나가 모든 VM에 설정됨
- [ ] CentOS Stream 9 VM이 cgroup v2로 부팅됨 (`test -f /sys/fs/cgroup/cgroup.controllers`)
- [ ] Infra DNS/NTP/NAT `192.168.14.62` 정상
- [ ] API VIP와 Service VIP/HAProxy 설정 완료
- [ ] 포트 매트릭스 승인
- [ ] DevOps VM에서 GitHub, PyPI, image registry 접근 가능
- [ ] Network 담당이 Registry TCP/5000 source를 Internal 노드 6대로 제한
- [ ] VM별 console 접근 또는 복구 경로 확보

## 7. 처음부터 끝까지 실행 순서

각 STEP은 한 번에 전부 붙여넣지 말고, 직전 STEP의 `[PASS]` 또는 기대 결과를 확인한 뒤 다음 STEP으로 진행한다. 대화형 shell은 한 명령이 실패해도 다음 줄을 계속 실행할 수 있다. `preflight`와 `baseline` 진입점은 이를 방어하기 위해 여섯 노드 중앙 제어 게이트를 다시 실행하며, `baseline`은 read-only network preflight가 성공해야 변경 작업으로 넘어간다.

### STEP 0 — PC5에서 DevOps VM 최초 SSH 준비

- 실행 서버: PC5 Windows 작업석, PC2 DevOps VM console
- 실행 문서: `00-docs/06-vscode-ssh-guide.md`
- 작업 내용: PC5 전용 SSH key를 만들고 public key만 `devops@192.168.14.21`에 설치
- 기대 결과: PC5의 VS Code에서 `neuroplan-devops`를 원격으로 열 수 있음
- 완료 기준:

```powershell
ssh neuroplan-devops 'hostname; id -un'
```

이 단계에서는 기존 VM의 IP, NetworkManager connection, route를 생성·수정·삭제하지 않는다.

### STEP 1 — DevOps 기반 준비

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `01-bootstrap/00-devops-bootstrap.sh`
- 전체 `onprem-k8s` 디렉터리를 새로 교체했다면 먼저 아래 한 명령을 실행한다. 이 명령은 승인된 디렉터리의 `*.sh`만 `0755`로 설정하며 YAML, 설정 파일과 문서 권한은 변경하지 않는다.

교체 전에 기존 `04-registry/08-images.lock`, `03-kubespray/inventory/mycluster/credentials/`, `artifacts/`, `logs/`가 있으면 저장소 밖의 승인된 위치에 보존한다. `.venv/`와 `03-kubespray/vendor/`가 교체 과정에서 사라진 경우에는 STEP 3으로 재생성하며, 다른 PC에서 복사해 재사용하지 않는다.

```bash
bash ./00-set-executable-permissions.sh
```

- 명령어:

```bash
./01-bootstrap/00-devops-bootstrap.sh
```

- 기대 결과: Python 3.11, Git/SSH 도구와 `~/.ssh/neuroplan_k8s` 생성
- 검증 방법:

```bash
python3.11 --version
ssh-keygen -lf ~/.ssh/neuroplan_k8s.pub
```

Private key는 DevOps VM 밖으로 복사하지 않는다.

기존 private key와 `.pub`가 불일치하거나 `.pub`가 유실된 경우 private key를
새로 만들거나 노드에 다시 복사하지 않는다. 다음 명령은 기존 private key에서
public algorithm/key blob만 추출하고, 임시 파일을 검증한 뒤 `.pub`만 원자적으로
교체한다. private key 내용은 출력하지 않는다.

```bash
bash ./01-bootstrap/06-repair-devops-public-key.sh
./01-bootstrap/05-verify-devops-control.sh
```

복구 전후 private key가 바뀌지 않으므로 노드의 `authorized_keys`에 이미 그
private key와 짝인 public key가 있다면 재배포할 필요가 없다. SSH 인증이 실제로
실패하는 노드에만 복구된 `.pub`를 STEP 2 console 방식으로 다시 설치한다.

### STEP 2 — Managed Node 최소 bootstrap

- 실행 서버: CP1~3, Worker1~3의 VMware console/root shell
- 실행 파일: `01-bootstrap/01-managed-node-bootstrap.sh`
- 선행 조건: 각 노드에서 DevOps `192.168.14.21:22`에 접속 가능하고 DNS/Internet이 준비되어 있어야 함
- 명령어:

권장 방식은 DevOps에서 실제 bootstrap script와 public key가 내장된 1회용 console 명령을 생성하는 것이다.

```bash
./01-bootstrap/04-render-k8sadmin-console-command.sh \
  > /tmp/k8sadmin-console-command.txt
cat /tmp/k8sadmin-console-command.txt
```

출력 전체를 복사해 CP1~3, Worker1~3의 root console에 각각 한 번씩 붙여넣는다. 출력은 하나의 subshell 명령이며 installer/public key 파일 생성, 권한 설정, 실행, 로컬 검증, 임시 파일 삭제를 모두 처리한다.

아래 SCP 방식은 VMware console의 긴 텍스트 붙여넣기가 불편할 때 사용하는 대안이다.

각 노드의 root console에서 스크립트와 public key만 DevOps로부터 가져온다. 저장소 전체를 CP/Worker에 복제하지 않는다.

```bash
scp devops@192.168.14.21:/home/devops/workspace/onprem-k8s/01-bootstrap/01-managed-node-bootstrap.sh /root/
scp devops@192.168.14.21:/home/devops/.ssh/neuroplan_k8s.pub /root/

chmod 0700 /root/01-managed-node-bootstrap.sh
/root/01-managed-node-bootstrap.sh /root/neuroplan_k8s.pub
```

DevOps SSH host fingerprint를 PC2 console 값과 대조한 뒤 승인한다. 전달되는 key는 public key뿐이며 private key는 DevOps 밖으로 나가지 않는다.

- 기대 결과: `k8sadmin`, SSH Server, Python3, passwordless sudo
- 1차 검증 방법(DevOps VM):

먼저 각 VM console에서 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 결과를 기록한다. 다음 대화형 **등록 loop**에서 표시되는 fingerprint를 해당 console 값과 대조한 뒤에만 `yes`를 입력한다. `BatchMode`는 이 최초 등록이 끝난 뒤에만 사용한다. inventory가 IP로 접속하므로 별칭이 아니라 Management IP 여섯 개를 각각 등록해야 하며 `StrictHostKeyChecking=no`를 사용하지 않는다.

```bash
for ip in 192.168.14.31 192.168.14.32 192.168.14.33 \
          192.168.14.41 192.168.14.42 192.168.14.43; do
  ssh -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=ask \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -i ~/.ssh/neuroplan_k8s k8sadmin@"$ip" \
    'hostname -s'
done
```

여섯 fingerprint를 모두 등록한 뒤 무인·strict 검증을 수행한다.

```bash
for ip in 192.168.14.31 192.168.14.32 192.168.14.33 \
          192.168.14.41 192.168.14.42 192.168.14.43; do
  ssh -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -i ~/.ssh/neuroplan_k8s k8sadmin@"$ip" \
    'set -eu; test "$(id -un)" = k8sadmin; test "$(sudo -n id -u)" = 0; python3 --version'
done
```

public key 파일을 SCP로 가져오기 어렵다면 DevOps에서 다음 한 줄을 복사한다.

```bash
cat ~/.ssh/neuroplan_k8s.pub
```

그 후 각 노드 console에서 인자 없이 스크립트를 실행하고 public key 한 줄을 붙여넣어도 된다.

```bash
/root/01-managed-node-bootstrap.sh
```

성공 후 노드에 임시 전달한 두 파일을 제거한다.

```bash
rm -f /root/01-managed-node-bootstrap.sh /root/neuroplan_k8s.pub
```

`02-bootstrap-all-managed-nodes.sh`는 과거 명령 호환용 이름만 유지하며 더 이상 root SSH bootstrap을 수행하지 않는다. 현재는 `05-verify-devops-control.sh`를 호출하는 읽기 전용 alias다. Bootstrap은 IP, route, swap, sysctl 또는 Kubernetes 패키지를 변경하지 않는다.

#### STEP 2A — 선택: PC5 VS Code key를 전체 VM에 배포

CP/Worker를 PC5에서 직접 진단해야 할 때만 사용한다. 중앙 구축에는 필요하지 않다. `k8sadmin`이 생성된 뒤 PC2 DevOps VM의 `devops` 계정에서 실행한다.

```bash
./01-bootstrap/03-distribute-pc5-vscode-key.sh \
  /tmp/neuroplan_vscode_pc5.pub
```

이후 PC5에서 A 담당 노드를 검사한다.

```powershell
ssh -o BatchMode=yes neuroplan-cp1 'hostname; id -un'
ssh -o BatchMode=yes neuroplan-worker1 'hostname; id -un'
```

**VMware Snapshot A:** 여섯 노드의 SSH/Python/sudo 검증 직후.

#### STEP 2B — 필수: DevOps 중앙 제어 게이트

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `01-bootstrap/05-verify-devops-control.sh`
- 명령어:

```bash
./01-bootstrap/05-verify-devops-control.sh
```

- 기대 결과: CP1~3와 Worker1~3 모두 public-key SSH, `k8sadmin`, `sudo -n`, Python3, 고정 NIC가 `[PASS]`
- 실패 시: Kubespray로 넘어가지 않고 해당 노드의 host fingerprint, `authorized_keys`, SELinux context, sudoers를 먼저 고친다.
- 범위: LB/DB/NFS/Infra는 의도적으로 검사하지 않는다.

#### STEP 2C — 전체 VM 중앙 NTP 설정

- 실행 서버/계정: PC2 DevOps VM `192.168.14.21` / `devops`
- 실행 파일: `01-bootstrap/08-configure-all-vm-ntp.sh`
- 구성 구조: Infra `192.168.14.62` → `3.kr.pool.ntp.org`, 나머지 12대 VM → Infra

DevOps에서 한 번 실행한다.

```bash
cd ~/onprem-k8s
./00-set-executable-permissions.sh
./01-bootstrap/08-configure-all-vm-ntp.sh
```

CP/Worker는 `k8sadmin` 공개키와 passwordless sudo를 사용한다. Infra/LB/DB/NFS에
DevOps 공개키가 없으면 실행 도중 기존 root SSH 암호를 각 호스트가 요청할 수 있다.
암호는 script, 인자, 환경변수 또는 로그에 저장하지 않는다.

Infra의 firewalld에 NTP 정책이 없으면 Network 담당 승인 후 다음처럼 다시 실행한다.

```bash
./01-bootstrap/08-configure-all-vm-ntp.sh --manage-infra-firewall
```

이 옵션은 Infra Management zone에 `192.168.14.0/24 → UDP/123` rich rule만
runtime/permanent로 추가하며, firewalld 자체를 켜거나 다른 zone을 열지 않는다.

성공 기준은 Infra server `PASS`, NTP clients `12/12 PASS`, Infra table
`PASS (12/12 observed)`이다. 각 client의 선택 source는 `192.168.14.62`,
Leap status는 `Normal`이어야 한다. 기존
`/etc/chrony.conf`는 실제 변경이 있을 때만 호스트별 고유 이름으로 백업된다.
재실행 시 동일 설정은 다시 변경하지 않는다.

운영 중인 Kubernetes·MariaDB의 시간을 강제로 이동하지 않도록 기본 실행은 기존
`makestep`을 비활성화한다. 서비스 설치 전 최초 시간 초기화에서만 아래 옵션을 쓴다.

```bash
./01-bootstrap/08-configure-all-vm-ntp.sh --allow-initial-step
```

Infra 서버만 별도로 복구하거나 준비할 때는 아래 server-only 절차를 사용한다.

- 실행 서버/계정: PC5 Infra VM `192.168.14.62` / `root`
- 실행 파일: `01-bootstrap/07-configure-infra-ntp.sh`
- 실행 책임: Infra/Network 담당자. A 담당의 Kubespray inventory에는 Infra를 추가하지 않는다.
- 기본 설정: upstream `3.kr.pool.ntp.org`, client 허용 `192.168.14.0/24`

저장소가 있는 DevOps VM에서 script만 Infra로 전달한다.

```bash
scp 01-bootstrap/07-configure-infra-ntp.sh root@192.168.14.62:/root/
```

Infra root console 또는 SSH에서 실행한다.

```bash
chmod 0700 /root/07-configure-infra-ntp.sh
/root/07-configure-infra-ntp.sh
```

다른 승인된 upstream을 사용할 때만 명시적으로 지정한다.

```bash
/root/07-configure-infra-ntp.sh --upstream ntp.example.org
```

script는 Infra 고정 IP를 확인하고 기존 `chrony.conf`를 고유 이름으로 백업한 뒤 managed block을 멱등 적용한다. 다른 승인 source/allow는 보존하며 충돌하는 `local`, `port 0`, loopback bind 설정은 덮지 않고 중단한다. upstream 동기화, UDP/123 listen, Management client 허용을 검증한다. firewalld 정책은 변경하지 않으며 NTP service가 열려 있지 않으면 Network 담당자가 표시된 명령을 승인·적용한 뒤 script를 다시 실행한다.

완료 후 DevOps에서 실제 client 질의를 확인한다.

```bash
ssh -i ~/.ssh/neuroplan_k8s k8sadmin@cp1 \
  'sudo timeout 15 chronyd -Q -t 10 "server 192.168.14.62 iburst"'
```

`No suitable source for synchronisation` 없이 offset 측정이 완료되어야 STEP 3 이후로 진행한다.

### STEP 3 — Kubespray와 전용 Ansible 설치

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `03-kubespray/02-install-kubespray.sh`, `03-verify-release.sh`
- 명령어:

```bash
./03-kubespray/02-install-kubespray.sh
source .venv/bin/activate
./03-kubespray/03-verify-release.sh
```

- 기대 결과: 중앙 `vendor/kubespray`와 전용 `.venv`, 정확한 commit/변수/checksum PASS
- 검증 방법:

```bash
git -C 03-kubespray/vendor/kubespray rev-parse HEAD
ansible --version
```

전역 Ansible이나 CP/Worker의 Ansible을 사용하지 않는다.

### STEP 4 — 기존 네트워크 read-only preflight

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `02-ansible/playbooks/04-preflight.yml`
- 명령어:

```bash
./02-ansible/00-ansiblectl.sh ping
./02-ansible/00-ansiblectl.sh preflight
```

- 기대 결과: Management/Internal/Data IP와 default route, Internet 상태 확인
- 검증 방법: 모든 host가 `ok`, IP assertion 통과
- 실패 시: Network 담당에게 현재 `ip -br address`, `ip route`, DNS/NTP 결과를 전달한다. 자동 IP 수정 코드는 없다.

### STEP 5 — 비-Kubernetes OS baseline

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `05-os-baseline.yml`, `06-validate-baseline.yml`
- 명령어:

```bash
./02-ansible/00-ansiblectl.sh baseline
```

- 기대 결과: inventory와 일치하는 short hostname, 관리 패키지, DevOps/CP/Worker 7대의 동일한 canonical `/etc/hosts`
- 공통 변수: `02-ansible/inventory/group_vars/all.yml`을 inventory와 함께 자동 로드
- 이름 규칙: bare alias(`cp1`, `worker1`, `lb1`)는 Management 전용이고 다른 Zone은 `-dmz`, `-k8s`, `-data` suffix를 사용
- 변경 안전성: 기존 `/etc/hosts`는 각 VM에 timestamp backup을 남긴 뒤 4-Zone 33개 레코드로 교체
- 적용 범위: 이 파일은 DevOps와 CP1~3/Worker1~3에만 배포하며 LB/DB/NFS/Infra VM 자체는 변경하지 않음
- 검증 방법: 33개 레코드와 67개 이름의 중복 여부 및 선언 IP와 실제 IPv4 해석이 모두 PASS

### STEP 6 — Docker Hub 인증과 DevOps Private Registry 설치

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `04-registry/06-configure-dockerhub-auth.sh`, `07-install-registry.yml`
- 명령어:

```bash
./04-registry/06-configure-dockerhub-auth.sh
./02-ansible/00-ansiblectl.sh registry
```

- 입력값: Docker Hub ID와 별도 생성한 **Read-only PAT**. 계정 password를 사용하지 않는다.
- 기대 결과: 저장소 밖의 `~/.config/containers/dockerhub-auth.json`(0600)과 `192.168.34.21:5000`의 rootful Podman Quadlet Registry, 데이터는 `/var/lib/onprem-registry`
- 검증 방법:

```bash
podman login --authfile "$HOME/.config/containers/dockerhub-auth.json" --get-login docker.io
stat -c '%U %a %n' "$HOME/.config/containers/dockerhub-auth.json"
./04-registry/09-registryctl.sh status
curl -fsS http://192.168.34.21:5000/v2/
sudo cat /etc/containers/registry-image.lock
```

PAT는 명령 인자·환경변수·Git 파일에 넣지 않고 script의 숨김 입력으로만 전달한다. auth JSON의 `auth` 값은 암호화가 아니라 되돌릴 수 있는 인코딩이므로 파일을 출력·복사·백업하지 않는다. PAT 교체는 script를 다시 실행한 뒤 STEP 12의 Secret도 갱신하고 기존 PAT를 Docker Hub에서 폐기한다.

요구사항에 따라 `registry:2`를 사용하지만, 현재 장기 유지보수 대상이 아닌 실습용 v2임을 승인 기록에 남긴다. Quadlet은 `Pull=never`로 고정되어 재기동 시 익명 pull로 되돌아가지 않는다. 장기 운영 전 Distribution v3 전환을 검토한다.

### STEP 7 — 필요한 image만 동기화

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `08-images.txt`, `08-sync-images.sh`, `09-verify-registry.sh`
- 명령어:

```bash
./04-registry/08-sync-images.sh
./04-registry/09-list-images.sh
./04-registry/09-verify-registry.sh
```

- 기대 결과: test/NGF image 5개와 digest lock 생성
- 검증 방법: `registry-podman-ok`, image 목록과 `08-images.lock`

Docker Hub 인증은 anonymous 제한을 계정 기준으로 바꾸지만 무료 Personal 계정 자체의 제한을 없애지는 않는다. 이 설계의 주된 제한 회피 수단은 필요한 image를 인증 상태에서 한 번만 받아 사설 Registry에 고정하고, 이후 노드는 그 Registry와 `IfNotPresent`만 사용하는 것이다.

**VMware Snapshot B:** OS baseline과 Registry 완료, Kubespray 실행 직전.

### STEP 8 — Kubespray preflight

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `03-kubespray/10-preflight.sh`
- 명령어:

```bash
./03-kubespray/10-preflight.sh
```

- 기대 결과: inventory, SSH/sudo, Internal Node IP, Kubespray API VIP 원본과 Registry 경로 확인
- 검증 방법: 마지막 `Kubespray preflight completed`

API가 아직 없으면 VIP TCP가 `connection refused`일 수 있지만 timeout이면 LB/방화벽을 먼저 해결한다. API 접속에는 BIND A 레코드를 요구하지 않는다.

### STEP 9 — Kubernetes HA 클러스터 배포

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `03-kubespray/11-deploy-cluster.sh`
- 명령어:

```bash
./03-kubespray/11-deploy-cluster.sh
```

- 기대 결과: CP 3 + etcd 3 + Worker 3, Calico/CoreDNS/Metrics/Gateway API와 `secretbox` 기반 Secret-at-rest 암호화
- 검증 방법: `logs/11-cluster-*.log`의 PLAY RECAP에 실패 없음

첫 배포 중 `03-kubespray/inventory/mycluster/credentials/`에 복구용 credential이 생성된다. 이 디렉터리는 Git에서 제외되며, 클러스터 정상화 직후 접근 통제된 별도 암호화 저장소에 백업한다. etcd snapshot과 같은 NFS 위치에 두지 않는다.

실패했다고 `reset.yml`부터 실행하지 않는다. 첫 실패 task를 저장하고 [07-troubleshooting/36-recovery.md](07-troubleshooting/36-recovery.md)를 따른다.

### STEP 10 — DevOps kubectl client 설치

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `03-kubespray/12-install-devops-client.sh`
- 명령어:

```bash
./03-kubespray/12-install-devops-client.sh
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
```

- 기대 결과: DevOps VM에서 kubectl과 API VIP kubeconfig 사용
- 검증 방법:

```bash
kubectl get nodes -o wide
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

기존 클러스터에 과거 API FQDN이 남아 있다면 add-on 설치 전에 다음 유지보수
작업으로 원본, kubeadm 저장 설정과 모든 노드 kubeconfig를 VIP로 수렴한다.

```bash
./03-kubespray/14-pin-api-vip-endpoint.sh status
CONFIRM_API_VIP_ENDPOINT=apply \
  ./03-kubespray/14-pin-api-vip-endpoint.sh apply
./03-kubespray/14-pin-api-vip-endpoint.sh verify
```

이 작업은 전면 백업 후 kubelet endpoint가 바뀌는 노드를 한 대씩 재시작하고
매번 Lease 갱신과 Ready를 확인한다. `clusterDomain`, CoreDNS, NodeLocal DNS,
인증서, etcd 데이터와 VIP 소유권은 변경하지 않는다.

**VMware Snapshot C:** 6 Node Ready, etcd/CoreDNS/Calico/Metrics/Gateway API 검증 직후.

### STEP 11 — Helm과 NGINX Gateway Fabric 설치

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `13-install-helm.sh`, `14-install-ngf.sh`
- 명령어:

```bash
./05-k8s-addons/13-install-helm.sh
export PATH="$HOME/.local/bin:$PATH"
./05-k8s-addons/14-install-ngf.sh
```

- 기대 결과: NGF 2.6.7 controller, GatewayClass `nginx`
- 검증 방법:

```bash
helm -n nginx-gateway list
kubectl get gatewayclass nginx
kubectl -n nginx-gateway get deployment,pod -o wide
```

이 단계는 Gateway API CRD를 다시 설치하지 않는다.

### STEP 12 — Docker Hub pull Secret, Gateway와 검증 workload 적용

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `12-create-dockerhub-pull-secret.sh`, `15`~`22`
- 명령어:

```bash
./05-k8s-addons/12-create-dockerhub-pull-secret.sh
./05-k8s-addons/22-apply-platform-test.sh
```

- 기대 결과: `application/dockerhub-pull`과 default ServiceAccount 참조, Probe/Anti-Affinity/HPA/PDB, 한 개의 HTTPS Gateway와 `/validation` HTTPRoute
- 검증 방법:

```bash
kubectl -n application get secret dockerhub-pull -o jsonpath='{.type}{"\n"}'
kubectl -n application get serviceaccount default -o jsonpath='{.imagePullSecrets[*].name}{"\n"}'
```

출력은 각각 `kubernetes.io/dockerconfigjson`, `dockerhub-pull`이어야 한다. Secret의 YAML/JSON 또는 `.data`는 출력하지 않는다. 이어서 Gateway `Accepted/Programmed`, HTTPRoute `Accepted/ResolvedRefs`를 확인한다.

NGF는 Gateway마다 data-plane Service를 만들고 `30443`은 cluster-wide 단일 NodePort다. 실제 애플리케이션도 두 번째 Gateway를 만들지 않고 `application/neuroplan-gateway`에 HTTPRoute를 추가한다.

`19-create-test-tls.sh`는 Secret이 없을 때만 30일 self-signed 인증서를 만든다. 운영 전에 팀 인증서로 교체하며 key를 Git에 커밋하지 않는다.

Docker Hub pull Secret은 namespace별 리소스다. 현재 검증 workload와 NGF는 사설 Registry image를 사용하므로 Docker Hub 제한을 실제로 줄이는 단계는 STEP 6~7이고, 이 Secret은 `application` namespace에서 향후 `docker.io` image를 직접 사용할 때를 위한 인증 경로다. Secret 값도 암호화된 비밀번호가 아니므로 YAML/JSON으로 출력하지 않는다. Kubespray가 클러스터 생성 전에 수행하는 runtime pull에는 Kubernetes Secret이 적용되지 않는다.

### STEP 13 — 전체 자동 검증

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `06-validation/23`~`30`
- 명령어:

```bash
./06-validation/30-run-all.sh
```

- 기대 결과: 다음 항목 전체 PASS
  - SSH/Node hostname와 IP
  - 6 Node Ready, 역할 분리
  - API VIP, stacked etcd, Control Plane
  - API Server Secret encryption provider
  - Calico/CoreDNS/Pod-to-Pod/Pod-to-Service/DNS/egress
  - Metrics Server/HPA
  - Probe/Self-Healing/Anti-Affinity/PDB
  - Gateway API/NGF/HTTPRoute/Worker별 30443/Service VIP
- 검증 방법: 마지막 `Validation summary: ... FAIL=0`

HPA를 생략한 빠른 재검사는 다음과 같다.

```bash
RUN_HPA_TESTS=0 ./06-validation/30-run-all.sh
```

### STEP 14 — etcd snapshot 및 인계

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `07-troubleshooting/33-etcd-snapshot.sh`
- 명령어:

```bash
./07-troubleshooting/33-etcd-snapshot.sh
```

- 기대 결과: `logs/etcd-snapshots/<timestamp>/`에 snapshot과 상대경로 SHA-256
- 검증 방법: 스크립트의 `sha256sum -c` PASS
- 후속: NFS 담당자의 `/backup/etcd`에 snapshot과 SHA-256 두 파일을 복사하고 restore 리허설 기록을 남긴다. `credentials/kube_encrypt_token.creds`를 NFS snapshot 옆에 복사하지 말고 별도의 암호화된 secret store에 보관한다. 둘 중 하나라도 잃으면 복구가 불완전해질 수 있다.

### STEP 15 — PC1/PC3 물리 장애 시연

- 실행 서버/계정: PC2 DevOps VM / `devops` + VMware 운영자 + Network 담당자
- 실행 파일: `06-validation/29-verify-ha-readonly.sh`
- 명령어:

```bash
./06-validation/29-verify-ha-readonly.sh
```

1. 정상 상태 baseline과 snapshot 확보
2. Network 담당자가 peer LB 상태 확인
3. PC1 또는 PC3 한 대만 수동 정지
4. 동일 스크립트 재실행
5. API/Service VIP, etcd quorum 2/3, 애플리케이션 응답 확인

스크립트는 VM 종료, etcd/HAProxy 중지 같은 외부 파괴 작업을 자동 수행하지 않는다.

**VMware Snapshot D:** NGF/워크로드/장애 시연 원복 후 전체 정상 상태.

### STEP 16 — 선택적 검증 리소스 정리

- 실행 서버/계정: PC2 DevOps VM / `devops`
- 실행 파일: `07-troubleshooting/37-cleanup-validation.sh`
- 명령어:

```bash
./07-troubleshooting/37-cleanup-validation.sh
```

validation label이 있는 workload/route만 지우며 namespace, Gateway, TLS Secret, NGF, CRD는 유지한다.

## 8. 실패와 재실행

진단 수집:

```bash
./07-troubleshooting/31-collect-diagnostics.sh
./07-troubleshooting/32-check-node.sh worker1
```

firewalld를 원래 영구 정책으로 다시 켜거나, 교육 환경에서 Calico 호환
정책을 추가해 켜야 할 때는
[00-docs/08-firewalld-calico-compatibility.md](00-docs/08-firewalld-calico-compatibility.md)를
먼저 읽는다. Calico 공식 권장 상태는 firewalld 비활성화다.

```bash
./07-troubleshooting/38-manage-k8s-firewalld.sh status

CONFIRM_FIREWALLD=restore-original \
  ./07-troubleshooting/38-manage-k8s-firewalld.sh restore-original

CONFIRM_FIREWALLD=apply-k8s \
  ./07-troubleshooting/38-manage-k8s-firewalld.sh apply-k8s
```

`restore-original`은 기존 zone/rich rule만 활성화하므로 앞서 확인한
Pod-to-Service/API 장애가 재현될 수 있다. `apply-k8s`는 기존 `nw-*` 정책을
보존하고 별도 관리 객체를 추가하며, 새 SSH 연결과 Pod 경로까지 성공한
경우에만 안전 rollback timer를 취소한다.

Worker 한 대 재시도:

```bash
./07-troubleshooting/34-retry-node.sh worker1
```

CP/etcd를 지정하면 quorum 의존성을 위해 전체 inventory를 재수렴한다.

Cluster reset은 데이터 제거 작업이다. 전체 승인과 snapshot 후에만 확인 문자열을 사용한다.

```bash
CONFIRM_RESET=neuroplan-destroy ./07-troubleshooting/35-reset-cluster.sh
```

주요 로그:

```bash
./07-troubleshooting/32-check-node.sh worker1
kubectl -n kube-system logs -l k8s-app=calico-node --tail=200
kubectl -n kube-system logs deployment/coredns --tail=200
kubectl -n kube-system logs deployment/metrics-server --tail=200
kubectl -n nginx-gateway logs deployment/ngf-nginx-gateway-fabric --all-containers --tail=200
```

## 9. 구축 완료 기준

- CP1~3와 Worker1~3가 모두 Ready이며 Internal-IP가 정확하다.
- CP와 Worker 역할이 합쳐지지 않았다.
- etcd 3멤버 healthy, 1대 장애 시 quorum 2/3이다.
- API VIP `192.168.34.100:6443`으로 반복 접근된다.
- Pod/Service CIDR, Calico VXLAN, CoreDNS, egress가 정상이다.
- Metrics Server와 HPA가 실제 scale-out한다.
- Probe, ReplicaSet self-healing, Anti-Affinity, PDB가 검증된다.
- Gateway API 1.5.1은 Kubespray가 한 번만 설치했다.
- NGF 2.6.7, HTTPRoute, Worker 3대 `30443`과 Service VIP 전체 경로가 정상이다.
- Registry image lock, 실제 버전, Kubespray commit, 배포/검증 로그가 남아 있다.
- Kubernetes Secret은 API Server encryption provider를 통해 etcd에 암호화되어 저장된다.
- etcd snapshot과 SHA-256이 NFS에 인계됐다.

## 10. 팀원에게 인계할 정보

- API endpoint와 최소 권한 kubeconfig/RBAC
- 노드/IP/role 및 실제 설치 버전표
- Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`
- Registry `192.168.34.21:5000`과 image naming/tag 규칙
- GatewayClass `nginx`, Gateway `application/neuroplan-gateway`
- hostname `app.nplan.local`, NodePort `30443`
- 테스트 route 제거 또는 실제 app route 교체 방법
- etcd snapshot 경로/해시, 별도 보관한 encryption credential의 복구 책임자와 복구 리허설 문서
- 장애 시연 증적과 변경 금지 시간

## 11. 남은 담당별 작업

### Network 담당

- HAProxy/Keepalived API/Service VIP와 health check 유지
- DNS `app.nplan.local`; Kubernetes API는 DNS가 아닌 VIP IP 사용
- Kubernetes 내부 Service DNS `*.svc.neuroplan.local`은 Infra BIND와 분리 유지
- 포트 매트릭스와 Registry source 제한 적용
- PC1/PC3 장애 시 VIP 전환 증적 제공

### DevOps 담당

- Git remote/branch 정책과 코드 백업
- Jenkins image build/tag/push, Registry retention
- Argo CD와 application GitOps 저장소 별도 구성
- kubeconfig/credential 발급과 폐기

### Data/Storage/Monitoring 담당

- NFS export, StorageClass/PV/PVC
- etcd snapshot 보존과 restore 리허설 지원
- Prometheus/Grafana/Loki/Alloy 배포와 retention
- MaxScale/DB egress 및 application Secret 제공

협업 체크박스는 [00-docs/04-handoff-checklist.md](00-docs/04-handoff-checklist.md)를 사용한다.

## 공식 참고 자료

- Kubespray v2.31.0: https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.31.0
- Kubespray HA mode: https://github.com/kubernetes-sigs/kubespray/blob/v2.31.0/docs/operations/ha-mode.md
- Kubespray containerd: https://github.com/kubernetes-sigs/kubespray/blob/v2.31.0/docs/CRI/containerd.md
- Kubernetes HA: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- Kubernetes ports: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Calico IP autodetection: https://docs.tigera.io/calico/latest/networking/ipam/ip-autodetection
- NGF 2.6.7 technical specification: https://github.com/nginx/nginx-gateway-fabric/blob/v2.6.7/README.md#technical-specifications
- Docker Hub pull limits: https://docs.docker.com/docker-hub/usage/pulls/
- Docker Hub personal access tokens: https://docs.docker.com/security/access-tokens/
- Podman login/authfile: https://docs.podman.io/en/latest/markdown/podman-login.1.html
- Kubernetes private registry Secret: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Kubernetes data encryption at rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Podman Quadlet: https://docs.podman.io/en/latest/markdown/podman-quadlet-basic-usage.7.html
- Distribution Registry API: https://distribution.github.io/distribution/spec/api/
