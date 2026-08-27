# DevOps 중앙 실행 정책

## 고정 운영 모델

클러스터 구축·검증·운영 명령의 **유일한 실행 거점**은 PC2의 DevOps VM이며, 로컬 Linux 사용자는 `devops`로 고정한다. PC5의 VS Code는 `devops@192.168.14.21`을 열기 위한 작업 화면일 뿐이다.

```text
PC5 VS Code
  └─ SSH: devops@192.168.14.21 (PC2 DevOps VM)
       ├─ Ansible/Kubespray SSH: k8sadmin@CP1~3
       └─ Ansible/Kubespray SSH: k8sadmin@Worker1~3
```

| 구간 | 실행 위치 | 사용자 | 용도 |
|---|---|---|---|
| 최초 DevOps 준비 | PC2 DevOps VM | `devops` | 도구·자동화 key 생성 |
| 최초 managed-node 계정 생성만 | 각 CP/Worker VMware console | `root` | `k8sadmin`·public key·NOPASSWD sudo 생성 |
| 전체 VM 중앙 NTP 설정·재검증 | PC2 DevOps VM | `devops` | `08-configure-all-vm-ntp.sh`만 실행 |
| Infra NTP 서버 단독 복구 | Infra VM | Infra/Network 담당 `root` | `07-configure-infra-ntp.sh`만 실행 |
| 그 외 모든 프로젝트 script | PC2 DevOps VM | `devops` | Ansible, Kubespray, Registry, add-on, 검증, 복구 |
| 원격 자동화 세션 | CP1~3, Worker1~3 | `k8sadmin` + `sudo` | 관리 작업 수행 |
| 직접 CP/Worker 로그인 | 필요 시에만 | `k8sadmin` | 읽기 전용 break-glass 장애 진단 |

각 CP/Worker console의 `root` 작업은 `01-managed-node-bootstrap.sh`를 한 번 실행하는 예외다. 중앙 NTP는 담당자 협의 후 DevOps에서 `08-configure-all-vm-ntp.sh`로만 설정한다. 이 도구는 CP/Worker에는 `k8sadmin`과 sudo를 사용하고 Infra/LB/DB/NFS에는 기존 root SSH를 NTP 작업에만 사용한다. Infra만 복구할 때는 Infra/Network 담당자가 `07-configure-infra-ntp.sh`를 실행한다. 두 도구 모두 비-Kubernetes VM을 inventory 또는 `k8sadmin` 범위에 넣지 않는다.

CP/Worker firewalld의 승인된 원상복구·lab 호환 구성은 PC2 DevOps VM에서
`38-manage-k8s-firewalld.sh`로만 수행한다. 이 중앙 entrypoint는 정확히 여섯
노드를 직렬 처리하고 기존 Network 담당 zone을 보존하며 새 SSH 연결과
자동 비활성화 안전 타이머를 사용한다. CP/Worker에서 `firewall-cmd`를 직접
실행하지 않는다.

PC5 ProxyJump 또는 DevOps에서 CP/Worker에 직접 로그인하는 것은 중앙 자동화가 실패했을 때의 break-glass 조회로만 허용한다. 이 세션에서는 `sudo` 변경, package 설치, 프로젝트 script 실행, Ansible/Kubespray 복제를 하지 않는다. 변경이 필요하면 원인을 확인한 뒤 DevOps 중앙 wrapper로 수행한다.

## 인증과 inventory

- 자동화 private key: DevOps의 `/home/devops/.ssh/neuroplan_k8s`
- Kubernetes client 설정: DevOps의 `/home/devops/.kube/config`
- 자동화 public key: 여섯 노드의 `/home/k8sadmin/.ssh/authorized_keys`
- 일반 Ansible inventory: `02-ansible/inventory/hosts.yaml`
- 일반 Ansible 공통 변수: `02-ansible/inventory/group_vars/all.yml`
- Kubespray inventory: `03-kubespray/inventory/mycluster/hosts.yaml`
- Kubespray Ansible 설정: `03-kubespray/ansible.cfg` (vendor 설정 대신 사용)
- 두 inventory의 원격 사용자는 `k8sadmin`으로 고정한다.
- 일반 Ansible inventory는 `ansible_become: true`를 사용한다. Kubespray inventory에는 전역 `ansible_become`을 두지 않고, 중앙 배포·복구 entrypoint가 `-b`를 명시한다. 이렇게 해야 Kubespray의 `delegate_to: localhost` 작업이 DevOps VM에서 불필요한 sudo를 요구하지 않는다.
- SSH는 Management `192.168.14.x`, Kubernetes node IP는 Internal `192.168.34.x`를 사용한다.
- 두 Ansible 설정은 `StrictHostKeyChecking=yes`, DevOps `known_hosts`, `IdentitiesOnly=yes`, password 비활성화를 강제한다.

`k8sadmin`의 password는 자동화에 사용하지 않는다. public-key SSH와 `sudo -n`이 모두 성공해야 한다. 자동화 private key를 PC5, CP/Worker 또는 Git으로 복사하지 않는다.

클러스터 add-on·validation·troubleshooting entrypoint는 `KUBECONFIG`를 `/home/devops/.kube/config`으로 고정한다. STEP 10의 `12-install-devops-client.sh`가 이 파일을 만들기 전에는 해당 script를 실행하지 않는다.

## 필수 중앙 제어 게이트

계정 설정 직후 PC2 DevOps VM의 프로젝트 루트에서 실행한다.

```bash
chmod +x 01-bootstrap/05-verify-devops-control.sh
./01-bootstrap/05-verify-devops-control.sh
```

이 검사는 다음을 변경 없이 확인한다.

- 현재 로컬 사용자가 `devops`인지
- 두 inventory가 `k8sadmin`을 사용하는지, 일반 Ansible inventory만 전역 become을 사용하고 Kubespray inventory는 이를 사용하지 않는지
- private/public key가 한 쌍이고 private key 권한이 안전한지
- `.pub`가 유실되거나 불일치하면 `06-repair-devops-public-key.sh`로 기존 private
  key에서 public algorithm/key blob만 원자적으로 복구하며 private key는 교체하거나
  출력하지 않는지
- 여섯 Management IP의 host key가 미리 확인되어 있는지
- `k8sadmin` public-key SSH, passwordless sudo, Python3
- 노드별 Management/Internal 및 Worker Data IP

여섯 노드가 모두 `[PASS]`일 때만 Kubespray 설치 단계로 넘어간다.

## 중앙 Ansible 실행

Kubespray 설치로 `.venv`가 준비된 뒤에는 action allowlist wrapper를 사용한다.

```bash
./02-ansible/00-ansiblectl.sh inventory
./02-ansible/00-ansiblectl.sh ping
./02-ansible/00-ansiblectl.sh preflight
./02-ansible/00-ansiblectl.sh baseline
./02-ansible/00-ansiblectl.sh registry
```

wrapper는 실행 사용자를 `devops`로 제한하고 중앙 inventory, 전용 virtualenv, `neuroplan_k8s` key를 항상 함께 사용한다.

## 범위 밖 노드

LB1/2, MariaDB, NFS, Infra VM은 Kubespray managed node가 아니며 위 `k8sadmin` 생성 대상도 아니다. 해당 VM의 계정·SSH·sudo는 담당자가 관리한다. `08-configure-all-vm-ntp.sh`의 중앙 NTP 변경과 Infra 단독 복구만 명시적 예외이며, A 담당자는 LB/DB/NFS/Infra에 managed-node bootstrap을 임의 적용하지 않는다.

## 금지 사항

- CP/Worker에서 Kubespray, Ansible, add-on 또는 validation script 직접 실행
- CP/Worker에 프로젝트 전체 복제
- `root` SSH를 일상 자동화 계정으로 사용
- password를 script, 환경변수, 파일, `sshpass`에 저장
- `StrictHostKeyChecking=no` 또는 확인하지 않은 host key 자동 승인
- private key를 DevOps VM 밖으로 복사
- 승인된 중앙 entrypoint 밖에서 CP/Worker firewalld stop/start/reload 또는 rule 변경
