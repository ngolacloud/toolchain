#!/usr/bin/env bash
# =============================================================================
# toolchain.sh — replica nesta ou noutra maquina as optimizacoes e o ambiente
#                de desenvolvimento medidos na sessao de 2026-11-21/22.
# =============================================================================
#
#   ./toolchain.sh doctor              so verifica, nao muda nada
#   ./toolchain.sh <fase>              DRY-RUN: mostra o que faria
#   ./toolchain.sh <fase> --apply      executa
#
# Fases:
#   doctor    inventario: o que esta instalado, o que falta, o que esta mal
#   os        optimizacoes de sistema (ver FASE OS: cada uma com a sua medicao)
#   rust      rustup + componentes + ferramentas cargo + perfis de build
#   go        Go (tarball oficial) + ferramentas
#   python    uv + ferramentas Python isoladas
#   node      Node via nvm + pnpm + biome
#   k8s       kubectl kustomize helm k9s kubectx stern kind kubeconform flux argocd
#   iac       opentofu terragrunt tflint checkov packer ansible-lint
#   sec       trivy grype syft cosign sops age vault hadolint dive skopeo
#   obs       k6 oha promtool amtool
#   cli       jq yq fd bat delta zoxide lazygit btop duf dust just direnv iperf3
#   selftest  valida o conteudo gerado pelos blocos --apply, sem o aplicar
#   harden    fundacoes de seguranca: sudo, firewall, chaves, cifra, Secure Boot
#   monitor   auditd, integridade de pacotes, linha de base de persistencia
#   delonix   chama o INSTALADOR OFICIAL do Delonix Runtime (nao reimplementa)
#   all       os-rust-go-python-node-k8s-iac-sec-obs-cli (delonix fica de fora)
#
# PRINCIPIOS, cada um aprendido num erro concreto desta sessao:
#
#   1. DRY-RUN POR OMISSAO. Nada muda sem --apply.
#   2. FALHAR ALTO. Um passo que falha imprime "!! FALHOU" com o exit code. Na
#      sessao original, uma funcao `run()` com um bug executava a descricao como
#      se fosse o comando, e quatro passos falharam em SILENCIO durante uma hora.
#   3. NUNCA SOBRESCREVER CONFIGURACAO. /etc/docker/daemon.json ja tinha o
#      runtime nvidia registado; um `echo > ` teria partido os contentores com
#      GPU. Tudo o que e JSON/TOML/YAML e FUNDIDO, com backup.
#   4. VERIFICAR ANTES DE DESLIGAR. A recomendacao de desligar o CUPS estava
#      errada: a maquina tinha tres impressoras configuradas. Cada servico e
#      testado quanto a uso real antes de ser tocado.
#   5. INVENTARIAR ANTES DE APAGAR. `docker system prune --volumes` levou o
#      volume nomeado de uma base de dados de desenvolvimento porque o
#      `system df` so mostrava um total agregado. Volumes nomeados sao
#      listados um a um, com nome e tamanho.
#   6. O LOG NAO VIVE ONDE O SCRIPT APAGA. A limpeza apagou o seu proprio log
#      por estar em /tmp/claude-*.
#   7. OLHAR PARA O ALVO, NAO PARA OS METADADOS. `ls -1` seguiu um symlink e
#      fez-me tomar um link pelo proprio destino que ia apagar. Tambem:
#      `nvidia-smi` ACORDA a GPU que se esta a medir, e `Installed-Size` de um
#      pacote `rc` nao e espaco em disco.
#   8. NAO COMPILAR EM BATERIA. Quatro builds a frio puseram o portatil a 110 W
#      e deram 25 min de autonomia. As fases que compilam verificam o ADP1.
#
# Reverter: cada mudanca de sistema escreve o estado anterior em
# $STATE_DIR/revert.log, com o comando exacto para a desfazer.
# =============================================================================

set -uo pipefail

APPLY=0
PHASE="${1:-doctor}"
for a in "${@:2}"; do [ "$a" = "--apply" ] && APPLY=1; done

STATE_DIR="${TOOLCHAIN_STATE:-$HOME/.local/state/toolchain}"
LOG="$STATE_DIR/toolchain-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$STATE_DIR"            # principio 6: fora de /tmp e de tudo o que se apaga
BIN="${TOOLCHAIN_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"

C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_Z=$'\033[0m'
[ -t 1 ] || { C_OK=; C_NO=; C_WARN=; C_DIM=; C_Z=; }

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
head2() { say ""; say "${C_DIM}── $* ${C_Z}"; }
ok()   { say "  ${C_OK}ok${C_Z}      $*"; }
no()   { say "  ${C_NO}!! FALHOU${C_Z} $*"; }
warn() { say "  ${C_WARN}aviso${C_Z}   $*"; }
skip() { say "  ${C_DIM}saltado${C_Z} $*"; }
dry()  { say "  ${C_DIM}[dry]${C_Z}   $*"; }

# run <descricao> -- <comando...>
# Principio 2: a descricao NUNCA entra no comando. O separador -- garante isso.
run() {
  local desc="$1"; shift
  [ "${1:-}" = "--" ] && shift
  if (( APPLY )); then
    if "$@" >>"$LOG" 2>&1; then ok "$desc"
    else no "$desc (exit $?) — ver $LOG"; return 1; fi
  else
    dry "$desc  ${C_DIM}:: $*${C_Z}"
  fi
}

# revert <comando para desfazer>
revert_note() { (( APPLY )) && printf '%s\n' "$*" >> "$STATE_DIR/revert.log"; }

# Deliberadamente so reconhece BINARIOS no PATH, nao funcoes nem aliases de
# shell. Verificado a 2026-11-22: um inventario feito numa shell interactiva
# dava `rg` como presente, quando era uma funcao injectada pelo ambiente e o
# ripgrep nao estava instalado. Um `doctor` que herda o ambiente de quem o
# chama mente sobre a maquina.
have() { command -v "$1" >/dev/null 2>&1 && [ "$(type -t "$1" 2>/dev/null)" = "file" ]; }

on_ac() {
  local a
  for a in /sys/class/power_supply/A*/online; do
    [ -f "$a" ] && [ "$(cat "$a")" = "1" ] && return 0
  done
  return 1
}

# Principio 8
require_ac() {
  if on_ac; then return 0; fi
  local cap="?"
  [ -f /sys/class/power_supply/BAT0/capacity ] && cap=$(cat /sys/class/power_supply/BAT0/capacity)
  warn "em BATERIA (${cap}%). Esta fase compila e pode puxar 70-110 W."
  warn "liga o carregador, ou passa --mesmo-em-bateria para insistir."
  for a in "$@"; do [ "$a" = "--mesmo-em-bateria" ] && { warn "a insistir por pedido explicito"; return 0; }; done
  return 1
}

pkg_mgr() {
  if   have apt-get; then echo apt
  elif have dnf;     then echo dnf
  elif have zypper;  then echo zypper
  elif have pacman;  then echo pacman
  else echo unknown; fi
}

# A familia e o que determina os NOMES dos pacotes, e por isso detecta-se pelo
# ID/ID_LIKE do os-release, nao pelo gestor. Zorin da ID=zorin
# ID_LIKE="ubuntu debian"; Manjaro da ID=manjaro ID_LIKE=arch; Rocky da
# ID=rocky ID_LIKE="rhel centos fedora".
distro_family() {
  local id="" like=""
  if [ -r /etc/os-release ]; then
    id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
    like=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")
  fi
  case " $id $like " in
    *" debian "*|*" ubuntu "*)              echo debian ;;
    *" rhel "*|*" fedora "*|*" centos "*)   echo rhel ;;
    *" arch "*)                             echo arch ;;
    *" suse "*|*" opensuse "*|*" sles "*)   echo suse ;;
    *) case "$(pkg_mgr)" in
         apt) echo debian ;; dnf) echo rhel ;; pacman) echo arch ;; zypper) echo suse ;;
         *) echo unknown ;;
       esac ;;
  esac
}

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# O EPEL e onde vivem muitas ferramentas nas distros Red Hat empresariais.
# Nao o acrescentamos: uma fonte de pacotes de terceiros e decisao de quem
# administra a maquina.
epel_hint() {
  [ "$(distro_family)" = "rhel" ] || return 0
  local id
  id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
  case "$id" in fedora) return 0 ;; esac
  dnf repolist enabled 2>/dev/null | grep -qi epel && return 0
  warn "EPEL nao esta activo. Varias ferramentas vivem la:"
  say  "    sudo dnf install -y epel-release   # RHEL/Rocky/Alma"
}

# No Arch, muita coisa so existe no AUR. Usamos um helper SE ja existir; nunca
# instalamos um helper de AUR nem compilamos pacotes do AUR sem o utilizador saber.
aur_helper() { for h in paru yay; do have "$h" && { echo "$h"; return 0; }; done; return 1; }

# =============================================================================
# DOCTOR — so verifica. E a fase que convem correr primeiro numa maquina nova.
# =============================================================================
fase_doctor() {
  head2 "sistema"
  say "  distro:    $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
  say "  kernel:    $(uname -r)"
  say "  gestor:    $(pkg_mgr)"
  say "  cpu:       $(nproc) threads  ·  ram: $(free -g | awk '/^Mem/{print $2}') GB"
  say "  alimentacao: $(on_ac && echo 'rede' || echo "bateria $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)%")"

  head2 "optimizacoes de SO (fase os)"
  local v
  v=$(grep -hoE '^SystemMaxUse=.*' /etc/systemd/journald.conf 2>/dev/null)
  [ -n "$v" ] && ok "journald com tecto: $v" || warn "journald SEM tecto (default = 10% do disco)"
  grep -qE '^\s*[^#].*\s/\s.*noatime' /etc/fstab 2>/dev/null \
    && ok "noatime na raiz" || warn "raiz SEM noatime (builds escrevem atime a cada leitura)"
  v=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
  [ "$v" = "50" ] && ok "vfs_cache_pressure=50" || warn "vfs_cache_pressure=$v (50 e melhor para builds)"
  v=$(cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null)
  case "$v" in *"[none]"*) ok "scheduler NVMe: none";; "") : ;; *) warn "scheduler NVMe: $v (none e o correcto em NVMe)";; esac
  if [ -f /sys/class/power_supply/BAT0/capacity ]; then
    local ef ed
    ef=$(cat /sys/class/power_supply/BAT0/energy_full 2>/dev/null || echo 0)
    ed=$(cat /sys/class/power_supply/BAT0/energy_full_design 2>/dev/null || echo 0)
    [ "$ed" -gt 0 ] && say "  saude da bateria: $((100*ef/ed))% da capacidade de origem"
  fi
  systemctl --user list-timers cargo-sweep.timer --no-pager --no-legend 2>/dev/null | grep -q cargo-sweep \
    && ok "timer cargo-sweep activo" || warn "SEM timer cargo-sweep (os target/ crescem sem tecto)"
  [ -f "$HOME/.config/sccache/config" ] && grep -q 'size' "$HOME/.config/sccache/config" 2>/dev/null \
    && ok "sccache com tecto de tamanho" || warn "sccache sem tecto declarado"

  head2 "servicos: candidatos a desligar, VERIFICADOS (principio 4)"
  local s
  for s in cups cups-browsed avahi-daemon; do
    systemctl is-enabled "$s" >/dev/null 2>&1 || continue
    if lpstat -p 2>/dev/null | grep -q '^printer'; then
      skip "$s — ha $(lpstat -p 2>/dev/null | grep -c '^printer') impressoras configuradas, MANTER"
    else warn "$s activo e sem impressoras configuradas: candidato"; fi
  done
  if systemctl is-enabled ModemManager >/dev/null 2>&1; then
    if mmcli -L 2>/dev/null | grep -qi "no modems"; then warn "ModemManager sem modems: candidato"
    else skip "ModemManager — ha modem"; fi
  fi
  if systemctl is-enabled snmpd >/dev/null 2>&1; then
    ss -lnu 2>/dev/null | grep -q ':161 ' && warn "snmpd a escutar em 161: superficie exposta" || warn "snmpd activo: candidato"
  fi
  if systemctl is-enabled systemd-networkd >/dev/null 2>&1; then
    local n
    n=$(networkctl list --no-legend 2>/dev/null | grep -vc unmanaged || echo 0)
    [ "${n:-0}" -le 1 ] && warn "systemd-networkd nao gere interface nenhuma: candidato (custa ~2 min de boot)" \
                        || skip "systemd-networkd gere $n interfaces"
  fi
  local b
  b=$(systemd-analyze 2>/dev/null | head -1)
  [ -n "$b" ] && say "  arranque: $b"
  local nf
  nf=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
  [ "$nf" -gt 0 ] && warn "$nf unidades em falha: $(systemctl --failed --no-legend 2>/dev/null | awk '{print $2}' | paste -sd' ')" || ok "0 unidades em falha"

  head2 "linguagens"
  have rustup && ok "rustup: $(rustup show active-toolchain 2>/dev/null | head -1)" || warn "rustup ausente"
  have cargo  && say "    cargo $(cargo --version 2>/dev/null | awk '{print $2}')  ·  target/ somados: $(
      find "$HOME" -maxdepth 6 -type d -name target -prune -exec du -xsm {} + 2>/dev/null | awk '{s+=$1} END {printf "%.1f GB", s/1024}')"
  have go     && ok "go: $(go version 2>/dev/null | awk '{print $3}')" || warn "go ausente"
  have uv     && ok "uv: $(uv --version 2>/dev/null | awk '{print $2}')" || warn "uv ausente (gestor Python recomendado)"
  have python3 && say "    python3 $(python3 -V 2>&1 | awk '{print $2}')"
  have node   && ok "node: $(node -v 2>/dev/null)" || warn "node ausente"
  have pnpm   && say "    pnpm $(pnpm -v 2>/dev/null)"
  have mise   && ok "mise: $(mise --version 2>/dev/null | head -1)" || say "    mise ausente (opcional: gere Python/Node/Go num so sitio)"

  head2 "ferramentas: presentes / em falta"
  local presentes=() faltam=()
  local t
  for t in kubectl kustomize helm k9s kubectx stern kind kubeconform flux argocd \
           tofu terraform terragrunt tflint checkov packer ansible ansible-lint \
           trivy grype syft cosign skopeo buildah dive hadolint \
           sops age vault gh glab act just direnv \
           k6 oha promtool amtool bpftrace \
           golangci-lint gopls dlv goreleaser \
           ruff pre-commit \
           biome jq yq fd rg bat delta zoxide lazygit btop duf dust mtr iperf3 \
           hyperfine sccache cross cargo-nextest cargo-deny cargo-audit cargo-sweep; do
    if have "$t"; then presentes+=("$t"); else faltam+=("$t"); fi
  done
  say "  presentes (${#presentes[@]}): ${presentes[*]}"
  say ""
  say "  ${C_WARN}em falta (${#faltam[@]})${C_Z}: ${faltam[*]}"

  head2 "Delonix"
  have delonix && ok "delonix: $(delonix --version 2>/dev/null | head -1)" || warn "delonix ausente — fase 'delonix'"
  local d
  for d in delonix-cri delonix-mcp delonix-mgmt delonix-node-api; do
    have "$d" && say "    $d presente"
  done

  say ""
  say "Relatorio em $LOG"
}

# =============================================================================
# FASE OS — cada ajuste com a medicao que o justifica.
# =============================================================================
fase_os() {
  local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  head2 "journald: tecto de 500 MB"
  # Sem tecto o default e 10% do disco. Num disco de 1 TB sao 93 GB; a maquina
  # de origem tinha 2,1 GB de journal acumulado.
  if grep -qE '^SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null; then
    skip "ja tem SystemMaxUse"
  else
    revert_note "sudo sed -i 's/^SystemMaxUse=500M/#SystemMaxUse=/' /etc/systemd/journald.conf"
    run "SystemMaxUse=500M" -- $SUDO sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
    run "vacuum do journal actual" -- $SUDO journalctl --vacuum-size=500M
  fi

  head2 "sysctl para cargas de compilacao"
  # vfs_cache_pressure=50: com buff/cache grande e arvores de build enormes,
  # manter dentries/inodes em memoria da ganho medivel.
  # swappiness=10: o swap e almofada para picos de linker, nao memoria de trabalho.
  if [ -f /etc/sysctl.d/99-dev-tuning.conf ]; then skip "99-dev-tuning.conf ja existe"
  else
    revert_note "sudo rm -f /etc/sysctl.d/99-dev-tuning.conf && sudo sysctl --system"
    if (( APPLY )); then
      printf 'vm.vfs_cache_pressure=50\nvm.swappiness=10\nfs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\n' \
        | $SUDO tee /etc/sysctl.d/99-dev-tuning.conf >/dev/null && $SUDO sysctl --system >/dev/null 2>&1 \
        && ok "sysctl aplicado" || no "sysctl"
    else dry "/etc/sysctl.d/99-dev-tuning.conf: vfs_cache_pressure=50, swappiness=10, inotify 1048576"; fi
  fi

  head2 "noatime na raiz"
  # Builds com milhares de ficheiros pequenos escrevem atime a cada leitura.
  if grep -qE '^\s*[^#].*\s/\s.*noatime' /etc/fstab; then skip "ja tem noatime"
  else
    warn "editar o fstab e tocar no arranque: faz-se com backup e validacao"
    if (( APPLY )); then
      $SUDO cp -a /etc/fstab "/etc/fstab.bak-toolchain-$(date +%F)"
      revert_note "sudo cp -a /etc/fstab.bak-toolchain-$(date +%F) /etc/fstab"
      $SUDO awk 'BEGIN{OFS="\t"} /^[^#]/ && $2=="/" && $4 !~ /noatime/ {$4=$4",noatime"} {print}' /etc/fstab > /tmp/fstab.$$ \
        && $SUDO cp /tmp/fstab.$$ /etc/fstab && rm -f /tmp/fstab.$$ \
        && $SUDO findmnt --verify >/dev/null 2>&1 \
        && $SUDO mount -o remount,noatime / \
        && ok "noatime activo agora e no proximo arranque" || no "noatime (fstab restaurado do backup)"
    else dry "acrescenta noatime a linha da raiz, valida com findmnt --verify, remonta"; fi
  fi

  head2 "Docker: limitar logs — FUNDE, nunca sobrescreve (principio 3)"
  if have docker; then
    if (( APPLY )); then
      $SUDO python3 -I -c '
import json, os, shutil
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    shutil.copy2(p, p + ".bak-toolchain")
    try: d = json.load(open(p))
    except Exception as e: raise SystemExit(f"daemon.json ilegivel ({e}): nao mexo")
d.setdefault("log-driver", "json-file")
lo = d.setdefault("log-opts", {})
lo.setdefault("max-size", "100m")   # respeita um tecto ja definido
lo["max-file"] = "3"
os.makedirs("/etc/docker", exist_ok=True)
json.dump(d, open(p, "w"), indent=4)
print("chaves preservadas:", sorted(k for k in d if k not in ("log-driver","log-opts")))
' >>"$LOG" 2>&1 && { ok "daemon.json fundido (backup em .bak-toolchain)"; revert_note "sudo cp /etc/docker/daemon.json.bak-toolchain /etc/docker/daemon.json && sudo systemctl restart docker"; } || no "daemon.json"
      run "reload do docker" -- $SUDO systemctl reload-or-restart docker
    else dry "acrescenta max-file=3 ao daemon.json preservando runtimes, storage-driver e registries"; fi
  else skip "docker ausente"; fi

  head2 "servicos: so os comprovadamente sem uso (principio 4)"
  local s
  for s in ModemManager snmpd kerneloops motd-news.timer; do
    systemctl is-enabled "$s" >/dev/null 2>&1 || { skip "$s nao esta activo"; continue; }
    case "$s" in
      ModemManager) mmcli -L 2>/dev/null | grep -qi "no modems" || { skip "$s — ha modem"; continue; } ;;
    esac
    revert_note "sudo systemctl enable --now $s"
    run "desligar $s" -- $SUDO systemctl disable --now "$s"
  done
  if lpstat -p 2>/dev/null | grep -q '^printer'; then
    skip "cups/cups-browsed/avahi MANTIDOS — $(lpstat -p 2>/dev/null | grep -c '^printer') impressoras configuradas"
  else
    warn "sem impressoras: podes desligar com"
    say  "    sudo systemctl disable --now cups cups-browsed avahi-daemon"
  fi
  if systemctl is-enabled systemd-networkd >/dev/null 2>&1 && have networkctl; then
    if [ "$(networkctl list --no-legend 2>/dev/null | grep -vc unmanaged)" -le 1 ] && [ -z "$(ls -A /etc/systemd/network 2>/dev/null)" ]; then
      revert_note "sudo systemctl enable --now systemd-networkd systemd-networkd.socket"
      run "desligar systemd-networkd (nao gere nada; ~2 min de boot)" -- $SUDO systemctl disable --now systemd-networkd
      run "desligar systemd-networkd-wait-online" -- $SUDO systemctl disable --now systemd-networkd-wait-online
      run "desligar systemd-networkd.socket" -- $SUDO systemctl disable --now systemd-networkd.socket
    else skip "systemd-networkd gere interfaces ou tem config propria"; fi
  fi

  head2 "perfil de desempenho so com carregador ligado"
  # Uma unidade de performance com RemainAfterExit=yes e sem condicao de
  # alimentacao fixa EPP=performance tambem em bateria: ~8,5 W a mais, medido.
  local unit=delonix-performance
  if systemctl cat "$unit" >/dev/null 2>&1; then
    local dir="/etc/systemd/system/$unit.service.d"
    if [ -f "$dir/override.conf" ] && grep -q ConditionACPower "$dir/override.conf" 2>/dev/null; then
      skip "$unit ja tem ConditionACPower"
    elif (( APPLY )); then
      $SUDO mkdir -p "$dir"
      printf '[Unit]\nConditionACPower=true\n' | $SUDO tee "$dir/override.conf" >/dev/null
      printf '%s\n%s\n' \
        'SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/systemctl --no-block start '"$unit"'.service"' \
        'SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/systemctl --no-block stop '"$unit"'.service"' \
        | $SUDO tee /etc/udev/rules.d/99-$unit.rules >/dev/null
      revert_note "sudo rm -rf $dir /etc/udev/rules.d/99-$unit.rules && sudo udevadm control --reload-rules"
      $SUDO udevadm control --reload-rules && $SUDO systemctl daemon-reload \
        && ok "ConditionACPower + regra udev (a condicao so e avaliada quando algo arranca a unidade; e a regra udev que a torna dinamica)" \
        || no "override de alimentacao"
    else dry "override ConditionACPower=true + regra udev para start/stop ao ligar o cabo"; fi
  else skip "$unit nao existe nesta maquina"; fi

  head2 "swap: 16 G bastam sem hibernacao"
  if grep -qr "resume=" /etc/default/grub /etc/initramfs-tools/conf.d/ 2>/dev/null; then
    skip "hibernacao configurada: nao mexer no swap"
  else
    local sz
    sz=$(awk '/^\/swapfile/{print $3}' /proc/swaps 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt 20000000 ]; then
      warn "swap de $((sz/1024/1024)) GB sem hibernacao. Para o reduzir a 16 G,"
      warn "a mao (envolve rm de um caminho de topo, decisao de pessoa):"
      say  "    sudo swapoff /swapfile && sudo truncate -s 16G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
    else skip "swap em tamanho razoavel"; fi
  fi

  head2 "cargo-sweep: tecto por target/ e artefactos de toolchains removidas"
  if ! have cargo-sweep; then warn "cargo-sweep ausente: corre a fase 'rust' primeiro"
  else
    local ud="$HOME/.config/systemd/user"
    if [ -f "$ud/cargo-sweep.timer" ]; then skip "timer ja existe"
    elif (( APPLY )); then
      mkdir -p "$ud"
      cat > "$ud/cargo-sweep.service" <<EOF
[Unit]
Description=cargo-sweep — tecto de tamanho e artefactos de toolchains removidas

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Environment=PATH=$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin
# --hidden e indispensavel: sem ela o --recursive salta .worktrees/, onde se
# acumularam 48 GB de target/ na maquina de origem.
# --time nao serve: so poda geracoes substituidas, e com uma geracao por target
# devolve 0 B. Verificado.
ExecStart=$HOME/.cargo/bin/cargo-sweep sweep --hidden --recursive --installed $HOME/workspace $HOME/workspaces
ExecStart=$HOME/.cargo/bin/cargo-sweep sweep --hidden --recursive --maxsize 4GB $HOME/workspace $HOME/workspaces
EOF
      cat > "$ud/cargo-sweep.timer" <<'EOF'
[Unit]
Description=Corre o cargo-sweep uma vez por semana

[Timer]
OnCalendar=Sun 04:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
      revert_note "systemctl --user disable --now cargo-sweep.timer && rm -f $ud/cargo-sweep.{service,timer}"
      systemctl --user daemon-reload && systemctl --user enable --now cargo-sweep.timer \
        && ok "timer semanal activo" || no "timer cargo-sweep"
    else dry "cria cargo-sweep.service (--installed + --maxsize 4GB, --hidden) e .timer semanal"; fi
  fi

  head2 "sccache com tecto rigido"
  local sc="$HOME/.config/sccache/config"
  if [ -f "$sc" ] && grep -q size "$sc" 2>/dev/null; then skip "ja tem tecto"
  elif (( APPLY )); then
    mkdir -p "$(dirname "$sc")"
    # UMA so seccao [cache.disk]: o TOML nao aceita a chave repetida, e um
    # segundo bloco faz o sccache recusar o ficheiro inteiro — o que para TODA
    # a compilacao com "Failed to load config file", um erro que nao nomeia a
    # duplicacao. Aconteceu na maquina de origem a 2026-08-28.
    cat > "$sc" <<EOF
[cache.disk]
dir = "$HOME/.cache/sccache"
size = 10737418240
EOF
    ok "tecto de 10 GiB"
  else dry "$sc com [cache.disk] size = 10 GiB"; fi

  say ""
  # `cond && cmd` como ultima instrucao devolve 1 quando cond e falsa, e isso
  # torna-se o retorno da funcao. O `|| true` fecha isso.
  (( APPLY )) && say "Revert: $STATE_DIR/revert.log" || true
}

# =============================================================================
# LINGUAGENS
# =============================================================================

fase_rust() {
  require_ac "$@" || return 1
  head2 "rustup e componentes"
  if ! have rustup; then
    run "instalar rustup" -- sh -c 'curl --proto =https --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal'
    export PATH="$HOME/.cargo/bin:$PATH"
  else ok "rustup presente: $(rustup show active-toolchain 2>/dev/null | head -1)"; fi
  run "componentes" -- rustup component add clippy rustfmt rust-analyzer rust-src llvm-tools

  head2 "targets de cross-compilacao"
  # musl: binarios estaticos para contentores scratch/distroless.
  # windows-gnu: agentes Windows a partir de Linux, sem precisar de MSVC.
  local t
  for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-pc-windows-gnu; do
    rustup target list --installed 2>/dev/null | grep -qx "$t" && skip "$t ja instalado" \
      || run "target $t" -- rustup target add "$t"
  done
  warn "macOS: o SDK da Apple so pode ser usado em hardware Apple, por licenca."
  warn "a saida defensavel e um runner macos no CI, nao cross-compilar daqui."

  head2 "linker de windows-gnu"
  pkg x86_64-w64-mingw32-gcc gcc-mingw-w64-x86-64 mingw64-gcc mingw-w64-gcc cross-x86_64-w64-mingw32-gcc || true
  pkg musl-gcc musl-tools musl-gcc musl musl-devel || true

  head2 "ferramentas cargo"
  # nextest: corre testes em paralelo com isolamento por processo e relatorios
  #   utilizaveis em CI. deny/audit: supply chain (RUSTSEC). sweep: tecto nos
  #   target/. cross: cross-compilacao em contentor. cyclonedx: SBOM.
  local tool
  for tool in cargo-nextest cargo-deny cargo-audit cargo-sweep cargo-cyclonedx \
              cargo-machete cargo-outdated cargo-expand sccache cross; do
    have "${tool#cargo-}" || have "$tool" && { skip "$tool presente"; continue; }
    run "cargo install $tool" -- cargo install --locked "$tool"
  done

  head2 "perfis de build recomendados"
  say "  Para a raiz de cada workspace. Medido num workspace Rust de 9 membros"
  say "  com 514 crates no lockfile, cargo test --workspace --no-run a frio:"
  say "    base 2840 MB  ->  line-tables-only 1984 MB (-30%)  ->  +deps debug=0 1513 MB (-47%)"
  cat <<'TOML' | tee -a "$LOG"

    [profile.dev]
    debug = "line-tables-only"
    split-debuginfo = "unpacked"

    [profile.dev.package."*"]
    debug = 0                     # dependencias sem debuginfo; o teu codigo mantem line tables

    [profile.release]
    lto = "thin"                  # "fat" custa 3-5x o tempo por ~2% de tamanho
    codegen-units = 1
    incremental = false
    split-debuginfo = "packed"    # .dwp ao lado: binario pequeno E core dumps legiveis

    [profile.release-ci]
    inherits = "release"
    codegen-units = 16
    lto = false
    strip = "debuginfo"

    [profile.dist]
    inherits = "release"
    strip = "symbols"             # usar com extraccao de simbolos (objcopy) antes

TOML
  warn "NAO por strip no perfil 'release': um binario despido torna um core dump"
  warn "de producao ilegivel. O strip pertence ao 'dist', depois da extraccao."
  warn "NAO definir CARGO_TARGET_DIR global: quebra scripts que dependem de"
  warn "./target/release/<bin>, e o cargo ja separa por triple com --target."
}

fase_go() {
  head2 "Go"
  # Tarball oficial em vez do pacote da distro: as distros ficam 1-2 versoes
  # atras, e um projecto que usa generics ou toolchains novos tropeca nisso.
  local want="${GO_VERSION:-1.26.2}"
  if have go && [ "$(go version | awk '{print $3}')" = "go$want" ]; then
    ok "go$want ja instalado"
  else
    warn "instala /usr/local/go$want a partir de go.dev (verifica o sha256 publicado)"
    if (( APPLY )); then
      local tgz="go${want}.linux-amd64.tar.gz" tmp; tmp=$(mktemp -d)
      if curl -fsSL -o "$tmp/$tgz" "https://go.dev/dl/$tgz" \
         && curl -fsSL -o "$tmp/sum" "https://go.dev/dl/?mode=json" ; then
        ( cd "$tmp" && sha256sum "$tgz" > sha.actual )
        say "    sha256 descarregado: $(awk '{print $1}' "$tmp/sha.actual")"
        warn "compara com o sha256 em https://go.dev/dl/ antes de confiar"
        sudo rm -rf "/usr/local/go" && sudo tar -C /usr/local -xzf "$tmp/$tgz" \
          && revert_note "sudo rm -rf /usr/local/go" && ok "go$want em /usr/local/go" || no "go"
      else no "download do Go"; fi
      rm -rf "$tmp"
    else dry "descarrega e extrai go$want para /usr/local/go"; fi
  fi
  grep -q '/usr/local/go/bin' "$HOME/.profile" 2>/dev/null || \
    warn "acrescenta ao PATH: export PATH=\$PATH:/usr/local/go/bin:\$(go env GOPATH)/bin"

  head2 "ferramentas Go"
  # golangci-lint agrega dezenas de linters numa so passagem; govulncheck le a
  # base de vulnerabilidades oficial do Go; dlv e o debugger.
  local p
  for p in golang.org/x/tools/gopls@latest \
           github.com/go-delve/delve/cmd/dlv@latest \
           golang.org/x/vuln/cmd/govulncheck@latest \
           go.uber.org/mock/mockgen@latest \
           github.com/golangci/golangci-lint/cmd/golangci-lint@latest; do
    local b
    b=$(basename "${p%@*}")
    have "$b" && { skip "$b presente"; continue; }
    run "go install $b" -- go install "$p"
  done
}

fase_python() {
  head2 "uv — gestor de Python, pacotes e ferramentas"
  # uv substitui pip+venv+pyenv+pipx numa so ferramenta escrita em Rust, com
  # resolucao e instalacao uma ordem de grandeza mais rapidas. E o que esta
  # maquina ja usa.
  if have uv; then ok "uv presente: $(uv --version 2>/dev/null | awk '{print $2}')"
  else run "instalar uv" -- sh -c 'curl -fsSL https://astral.sh/uv/install.sh | sh'; fi

  head2 "ferramentas Python, isoladas (uv tool)"
  # `uv tool install` poe cada ferramenta no seu ambiente: nunca se contamina
  # o Python do sistema nem se cria conflito de dependencias entre ferramentas.
  local t
  for t in ruff mypy pre-commit ansible-lint checkov; do
    have "$t" && { skip "$t presente"; continue; }
    run "uv tool install $t" -- uv tool install "$t"
  done
  warn "NUNCA 'pip install --user' num SO moderno: o PEP 668 marca o Python do"
  warn "sistema como gerido externamente, e furar isso parte actualizacoes."
}

fase_node() {
  head2 "Node"
  # nvm e o que esta maquina usa. O fnm e mais rapido mas trocar seria
  # disruptivo; respeita-se o que ja ca esta (ver tambem mise na fase doctor).
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    ok "nvm presente"
    # shellcheck disable=SC1091
    (( APPLY )) && { . "$HOME/.nvm/nvm.sh"; nvm install --lts >>"$LOG" 2>&1 && ok "Node LTS" || no "nvm install"; } \
                || dry "nvm install --lts"
  elif have node; then ok "node $(node -v) (sem nvm)"
  else run "instalar nvm" -- sh -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'; fi

  head2 "pnpm via corepack e ferramentas"
  # corepack vem com o Node e fixa a versao do gestor por projecto
  # (packageManager no package.json), o que torna os builds reproduziveis.
  have pnpm && ok "pnpm $(pnpm -v 2>/dev/null)" || run "corepack enable pnpm" -- corepack enable pnpm
  have biome && skip "biome presente" || run "biome (lint+format numa ferramenta)" -- pnpm add -g @biomejs/biome
  have tsc   && skip "typescript presente" || run "typescript" -- pnpm add -g typescript
}

# =============================================================================
# PLATFORM ENGINEERING / SRE / DEVOPS
# =============================================================================
# Estrategia de instalacao, por ordem de preferencia:
#   1. gestor de pacotes da distro  — assinado, actualiza com o sistema
#   2. go install                   — compila da fonte, sem binarios opacos
#   3. uv tool install              — para ferramentas Python, isoladas
#   4. release do GitHub            — ULTIMO recurso, com sha256 verificado
#
# O ponto 4 e o unico que descarrega e executa um binario de terceiros. Por
# isso `gh_bin` resolve o asset pela API do GitHub e SO instala se o sha256
# bater com o ficheiro de checksums publicado pelo upstream. Sem checksums,
# avisa e NAO instala.
# =============================================================================

# gh_bin <binario> <owner/repo> <regex_asset> [regex_checksums]
#
# Resolve o asset pela API do GitHub em vez de adivinhar o nome. Verificado a
# 2026-11-22: `releases/latest/download/<nome-fixo>` so funciona se o nome do
# asset NAO incluir a versao. No grype, syft e dive inclui, e o download dava
# 404 — tres falhas que pareciam problema de rede e eram URL errado.
#
# SO instala se o sha256 bater com o ficheiro de checksums publicado pelo
# upstream. Sem checksums, avisa e NAO instala: e o unico ponto do script que
# executa um binario de terceiros, e por isso o mais restritivo.
gh_bin() {
  local name="$1" repo="$2" apat="$3" cpat="${4:-(checksums|SHA256SUMS|sha256)}"
  have "$name" && { skip "$name presente"; return 0; }
  if ! (( APPLY )); then dry "$name <- github:$repo (asset ~ /$apat/, sha256 verificado)"; return 0; fi

  local json

  json=$(curl -fsSL --proto '=https' --tlsv1.2 \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) \
    || { no "$name: API do GitHub inacessivel"; return 1; }

  local urls

  urls=$(printf '%s' "$json" | python3 -I -c '
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
apat, cpat = sys.argv[1], sys.argv[2]
a=[x["browser_download_url"] for x in d.get("assets",[]) if re.search(apat, x["name"])]
c=[x["browser_download_url"] for x in d.get("assets",[]) if re.search(cpat, x["name"], re.I)]
print(a[0] if a else ""); print(c[0] if c else ""); print(d.get("tag_name",""))
' "$apat" "$cpat" 2>/dev/null) || { no "$name: resposta da API ilegivel"; return 1; }

  local aurl curl_ tag
  aurl=$(sed -n 1p <<<"$urls"); curl_=$(sed -n 2p <<<"$urls"); tag=$(sed -n 3p <<<"$urls")
  [ -n "$aurl" ] || { no "$name: nenhum asset de $repo@${tag:-latest} corresponde a /$apat/"; return 1; }
  [ -n "$curl_" ] || { no "$name: $repo@$tag nao publica checksums — NAO instalado"; return 1; }

  local tmp f
  tmp=$(mktemp -d)
  f="$tmp/$(basename "$aurl")"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$f" "$aurl" || { no "$name: download de $aurl"; rm -rf "$tmp"; return 1; }
  curl -fsSL -o "$tmp/SUMS" "$curl_" || { no "$name: download dos checksums"; rm -rf "$tmp"; return 1; }

  local want got
  want=$(grep -F "$(basename "$f")" "$tmp/SUMS" 2>/dev/null | awk '{print $1}' | head -1)
  got=$(sha256sum "$f" | awk '{print $1}')
  if [ -z "$want" ]; then no "$name: os checksums de $tag nao cobrem $(basename "$f") — NAO instalado"; rm -rf "$tmp"; return 1; fi
  if [ "$want" != "$got" ]; then no "$name: sha256 NAO BATE (esperado $want, obtido $got) — NAO instalado"; rm -rf "$tmp"; return 1; fi
  say "    $repo@$tag  sha256 verificado: ${got:0:16}..."

  case "$f" in
    *.tar.gz|*.tgz) tar -xzf "$f" -C "$tmp" ;;
    *.zip)          unzip -qo "$f" -d "$tmp" ;;
  esac
  local src
  src=$(find "$tmp" -type f -name "$name" -perm -u+x 2>/dev/null | head -1)
  [ -n "$src" ] || src=$(find "$tmp" -type f -name "$name" | head -1)
  if [ -n "$src" ]; then
    install -m 0755 "$src" "$BIN/$name" && ok "$name $tag -> $BIN/$name"
    revert_note "rm -f $BIN/$name"
  else no "$name: binario nao encontrado dentro do arquivo"; fi
  rm -rf "$tmp"
}

# pkg <binario> <deb> <rhel> <arch> [suse]
#   "-" = nao empacotado nessa familia; o chamador trata a alternativa.
# A tabela e best-effort: a matriz de CI (ubuntu/debian/fedora/rocky/arch)
# existe precisamente para expor um nome errado, e o run() falha alto.
pkg() {
  local b="$1" deb="${2:--}" rh="${3:--}" ar="${4:--}" su="${5:--}"
  have "$b" && { skip "$b presente"; return 0; }
  local fam name; fam=$(distro_family)
  case "$fam" in
    debian) name="$deb" ;; rhel) name="$rh" ;; arch) name="$ar" ;; suse) name="$su" ;;
    *) warn "$b: familia de distro desconhecida"; return 1 ;;
  esac
  if [ "$name" = "-" ] || [ -z "$name" ]; then
    if [ "$fam" = "arch" ] && h=$(aur_helper); then
      warn "$b: so no AUR. Com o helper que ja tens:  $h -S $b"
    else
      warn "$b: sem pacote em $fam — ver a alternativa na documentacao"
    fi
    return 1
  fi
  case "$fam" in
    debian) run "$b (apt: $name)"    -- $SUDO apt-get install -y -qq "$name" ;;
    rhel)   run "$b (dnf: $name)"    -- $SUDO dnf install -y -q "$name" ;;
    arch)   run "$b (pacman: $name)" -- $SUDO pacman -S --noconfirm --needed "$name" ;;
    suse)   run "$b (zypper: $name)" -- $SUDO zypper --non-interactive install --no-recommends "$name" ;;
  esac
}

go_install() {  # go_install <binario> <modulo@versao>
  local b="$1" m="$2"
  have "$b" && { skip "$b presente"; return 0; }
  have go || { warn "$b precisa de Go: corre a fase 'go'"; return 1; }
  run "$b (go install)" -- go install "$m"
}

fase_k8s() {
  epel_hint
  head2 "Kubernetes"
  pkg kubectl kubectl kubectl kubectl kubernetes-client
  go_install kustomize sigs.k8s.io/kustomize/kustomize/v5@latest
  have helm && skip "helm presente" || run "helm (script oficial)" -- sh -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
  go_install stern        github.com/stern/stern@latest
  go_install kind         sigs.k8s.io/kind@latest
  go_install kubeconform  github.com/yannh/kubeconform/cmd/kubeconform@latest
  # k9s: TUI para inspeccionar clusters sem decorar flags do kubectl
  gh_bin k9s derailed/k9s 'k9s_Linux_amd64\.tar\.gz$' 'checksums\.sha256$' 
  # kubectx/kubens sao shell puro: nada para verificar alem da fonte
  if ! have kubectx; then
    if (( APPLY )); then
      install -d "$BIN" && for s in kubectx kubens; do
        curl -fsSL -o "$BIN/$s" "https://raw.githubusercontent.com/ahmetb/kubectx/master/$s" && chmod +x "$BIN/$s"
      done && ok "kubectx + kubens" || no "kubectx"
    else dry "kubectx + kubens (scripts shell)"; fi
  else skip "kubectx presente"; fi
  warn "flux e argocd: CLIs de GitOps. Instala so o do teu controlador —"
  warn "ter os dois sem usar e superficie e confusao. Ver a doc de cada um."
}

fase_iac() {
  epel_hint
  head2 "Infraestrutura como codigo"
  # OpenTofu em vez de Terraform: fork sob a Linux Foundation depois da mudanca
  # de licenca da HashiCorp para BUSL. Esta maquina ja usa `tofu`.
  have tofu && ok "opentofu presente: $(tofu version 2>/dev/null | head -1)" \
            || warn "opentofu: ver https://opentofu.org/docs/intro/install/ (o instalador verifica assinatura GPG)"
  go_install terragrunt github.com/gruntwork-io/terragrunt@latest
  go_install tflint     github.com/terraform-linters/tflint@latest
  pkg packer packer - packer -
  pkg ansible ansible ansible ansible ansible
  have ansible-lint && skip "ansible-lint presente" || { have uv && run "ansible-lint (uv tool)" -- uv tool install ansible-lint; }
  have checkov && skip "checkov presente" || { have uv && run "checkov (uv tool)" -- uv tool install checkov; }
}

fase_sec() {
  epel_hint
  head2 "Supply chain e seguranca"
  # trivy: vulnerabilidades em imagens, FS e IaC. grype+syft: SBOM e scan da
  # Anchore. cosign: assinatura de artefactos (sigstore). sops+age: segredos
  # cifrados em git, com chaves modernas em vez de GPG.
  have trivy && skip "trivy presente" || warn "trivy: usa o repositorio apt da Aqua (assinado) — ver a doc"
  gh_bin grype anchore/grype 'linux_amd64\.tar\.gz$' 'checksums\.txt$' 
  gh_bin syft anchore/syft 'linux_amd64\.tar\.gz$' 'checksums\.txt$' 
  go_install cosign github.com/sigstore/cosign/v2/cmd/cosign@latest
  go_install sops   github.com/getsops/sops/v3/cmd/sops@latest
  pkg age age age age age
  pkg skopeo skopeo skopeo skopeo skopeo
  pkg buildah buildah buildah buildah buildah
  go_install hadolint github.com/hadolint/hadolint@latest || warn "hadolint e Haskell: usa a imagem oficial ou o binario do release"
  gh_bin dive wagoodman/dive 'linux_amd64\.tar\.gz$' 
  warn "vault: a CLI vem do repositorio da HashiCorp. Instala so se usares Vault."
}

fase_obs() {
  epel_hint
  head2 "Observabilidade e carga"
  # k6 para carga com scripts em JS; oha e um hey/ab moderno em Rust.
  have k6 && skip "k6 presente" || warn "k6: repositorio apt oficial da Grafana (assinado) — ver a doc"
  have oha && skip "oha presente" || { have cargo && run "oha (cargo)" -- cargo install --locked oha; }
  pkg promtool prometheus golang-github-prometheus prometheus golang-github-prometheus-prometheus
  pkg amtool prometheus-alertmanager - alertmanager -
  pkg sysstat sysstat sysstat sysstat sysstat
  pkg bpftrace bpftrace bpftrace bpftrace bpftrace
  pkg iperf3 iperf3 iperf3 iperf3 iperf3
  pkg mtr mtr-tiny mtr mtr mtr
}

fase_cli() {
  epel_hint
  head2 "Utilitarios de linha de comando"
  pkg jq jq jq jq jq
  pkg rg ripgrep ripgrep ripgrep ripgrep
  # fd e bat: no Debian os pacotes instalam `fdfind` e `batcat` por conflito de
  # nomes com outros pacotes; em Fedora e Arch instalam `fd` e `bat`. Por isso
  # instala-se o PACOTE da familia e depois normaliza-se o NOME do binario.
  pkg fd  fd-find fd-find fd fd || true
  pkg bat bat     bat     bat bat || true
  local real want
  for pair in fdfind:fd batcat:bat; do
    real="${pair%%:*}"; want="${pair##*:}"
    if have "$real" && ! have "$want"; then
      run "link $want -> $real" -- ln -sf "$(command -v "$real")" "$BIN/$want"
      revert_note "rm -f $BIN/$want"
    fi
  done
  pkg btop btop btop btop btop
  pkg duf duf duf duf -
  pkg delta git-delta git-delta git-delta git-delta
  go_install yq github.com/mikefarah/yq/v4@latest
  have just     && skip "just presente"     || { have cargo && run "just (cargo)" -- cargo install --locked just; }
  have dust     && skip "dust presente"     || { have cargo && run "du-dust (cargo)" -- cargo install --locked du-dust; }
  pkg zoxide zoxide zoxide zoxide zoxide
  pkg direnv direnv direnv direnv direnv
  have lazygit  && skip "lazygit presente"  || go_install lazygit github.com/jesseduffield/lazygit@latest
  pkg gh gh gh github-cli gh
}

# =============================================================================
# DELONIX — delega no instalador oficial. NAO reimplementa.
# =============================================================================
fase_delonix() {
  head2 "Delonix Runtime"
  say "  O Delonix tem um instalador oficial de ~1900 linhas que faz muito mais"
  say "  do que copiar um binario: detecta a distro (apt/dnf/zypper/pacman),"
  say "  instala TODAS as dependencias de runtime (contentores E VMs), configura"
  say "  subuid/subgid e AppArmor para o modo rootless, trata de CDI da NVIDIA,"
  say "  cloud-hypervisor e firmware EDK2. Reimplementar isso seria pior e ficaria"
  say "  desactualizado. Este script chama-o."
  say ""
  local LOCAL_INSTALLER=""
  for c in "$HOME/workspace/ngolacloud/delonix-runtime/scripts/install.sh" \
           "$HOME/workspaces/ngolacloud/delonix/scripts/install.sh"; do
    [ -f "$c" ] && { LOCAL_INSTALLER="$c"; break; }
  done

  local FLAGS="${DELONIX_FLAGS:---with-cri}"
  say "  flags: $FLAGS   (DELONIX_FLAGS=... para mudar)"
  say "  uteis: --with-cri (no Kubernetes) · --production (tuning de escala)"
  say "         --no-vm (so contentores) · --user (binario em ~/.local/bin)"
  say "         --with-image-build (libguestfs; BAIXA uma fronteira de seguranca"
  say "         do host ao tornar /boot/vmlinuz-* legivel — ler a seccao propria)"
  say ""
  if [ -n "$LOCAL_INSTALLER" ]; then
    ok "instalador local encontrado: $LOCAL_INSTALLER"
    run "correr o instalador oficial" -- bash "$LOCAL_INSTALLER" $FLAGS
  else
    warn "sem checkout local. O caminho publicado e:"
    say  "    curl -fsSL https://github.com/angolardevops/delonix-runtime/releases/latest/download/install.sh | bash -s -- $FLAGS"
    warn "nao o corro por ti: executar um script vindo da rede e decisao de quem"
    warn "confia na origem, e deve passar por uma leitura previa."
  fi
}

# =============================================================================
# HARDEN — fundacoes. Sem estas, monitorizar e observar a porta aberta.
# =============================================================================
fase_harden() {
  head2 "sudo sem senha — o vector mais barato de fechar"
  # Um `build.rs` de uma crate, um `postinstall` de npm ou um `go generate`
  # correm com a tua identidade. Com NOPASSWD:ALL correm `sudo` sem prompt, e a
  # escalada e silenciosa. Uma senha nao para um atacante determinado, mas
  # quebra a automatizacao.
  # `sudo -l` mostra a POLITICA EFECTIVA, que e o que interessa. Um ficheiro em
  # sudoers.d pode conter NOPASSWD:ALL e nao ter efeito nenhum: as regras sao
  # todas avaliadas e a ULTIMA que casa ganha, por isso um `%sudo ALL=(ALL:ALL)
  # ALL` declarado DEPOIS do @includedir sobrepoe-se a ele.
  #
  # NAO usar `sudo -n true` como prova: ele tem exito sempre que exista uma
  # credencial em cache de um sudo recente (~15 min). Verificado a 2026-11-22,
  # num caso em que `sudo -n true` passava, o ficheiro continha NOPASSWD:ALL, e
  # o sudo pedia senha de facto — a regra estava escrita e inactiva.
  local pol np
  if pol=$($SUDO -n -l 2>/dev/null); then
    np=$(grep -E "NOPASSWD" <<<"$pol" | head -3)
  else
    warn "nao foi possivel ler a politica sem senha; corre esta fase num terminal"
    np=""
  fi
  if [ -z "$np" ]; then ok "sem regras NOPASSWD:ALL"
  else
    warn "politica efectiva com NOPASSWD: $(tr '\n' ' ' <<<"$np")"
    warn "qualquer processo teu obtem root sem prompt — incluindo scripts de build"
    say  "    Se precisas de comandos sem senha, declara ESSES em vez de ALL:"
    say  "      walter ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart <servico>"
    if (( APPLY )); then
      local f; for f in $np; do
        $SUDO cp -a "$f" "$f.bak-toolchain"
        revert_note "sudo cp -a $f.bak-toolchain $f"
        # Comenta a regra em vez de apagar o ficheiro: reversivel e auditavel.
        $SUDO sed -i -E 's/^([^#].*NOPASSWD:[[:space:]]*ALL.*)$/# desactivado por toolchain harden: \1/' "$f"
      done
      if $SUDO visudo -c >/dev/null 2>&1; then
        # -k invalida a credencial em cache: sem isto o teste passa sempre.
        $SUDO -k
        if $SUDO -n true 2>/dev/null; then no "ainda passa sem senha: ha outra regra activa"
        else ok "sudo passa a pedir senha"; fi
      else
        no "visudo -c reprovou: a restaurar do backup"
        for f in $np; do $SUDO cp -a "$f.bak-toolchain" "$f"; done
      fi
    else dry "comenta a regra NOPASSWD:ALL, valida com visudo -c, restaura se reprovar"; fi
  fi

  head2 "grupo docker: equivalente a root"
  id -nG | tr ' ' '\n' | grep -qx docker \
    && warn "estas no grupo docker. Quem esta nele monta / num contentor e escreve onde quiser. Para rootless: podman, ou o modo rootless do Delonix" \
    || ok "fora do grupo docker"

  head2 "firewall"
  if ! have ufw; then warn "ufw ausente"; else
    if $SUDO ufw status 2>/dev/null | grep -qi "Status: active"; then ok "ufw activo"
    else
      warn "ufw INACTIVO (a unidade estar 'enabled' nao e a mesma coisa)"
      say  "  o que esta a escutar em todas as interfaces:"
      $SUDO ss -lntH 2>/dev/null | awk '$4 ~ /^(0\.0\.0\.0|\[::\])/ {print "    "$4}' | sort -u | head -8
      warn "antes de activar: as pontes de VMs e contentores precisam de passar,"
      warn "senao as VMs perdem DHCP e DNS. Melhor ainda e por os servicos a"
      warn "escutar so em 127.0.0.1, o que remove a exposicao na origem."
      if (( APPLY )); then
        revert_note "sudo ufw disable"
        $SUDO ufw --force default deny incoming >/dev/null 2>&1
        $SUDO ufw --force default allow outgoing >/dev/null 2>&1
        $SUDO ufw allow in on lo >/dev/null 2>&1
        local br
        for br in $(ip -br link show type bridge 2>/dev/null | awk '{print $1}'); do
          $SUDO ufw allow in on "$br" >/dev/null 2>&1 && say "    permitido: $br"
        done
        $SUDO ufw --force enable >/dev/null 2>&1 && ok "ufw activo (deny incoming, pontes permitidas)" || no "ufw enable"
      else dry "default deny incoming, allow lo e cada ponte, depois ufw enable"; fi
    fi
  fi

  head2 "chave SSH sem passphrase"
  # Todas as chaves privadas, nao so as que se chamam id_*: a verificacao
  # inicial desta auditoria olhou apenas para id_* e deixou passar uma segunda
  # chave sem passphrase. Detecta-se pelo CONTEUDO (cabecalho PEM/OpenSSH),
  # que e o que define uma chave privada, nao pelo nome.
  local k found=0
  while IFS= read -r k; do
    [ -f "$k" ] || continue
    if ! grep -q "ENCRYPTED\|bcrypt" "$k" 2>/dev/null; then
      warn "$(basename "$k") sem passphrase — num disco sem cifra, e a tua identidade em claro"
      say  "    ssh-keygen -p -f $k"
      found=1
    fi
  done < <(grep -rlE "^-----BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY-----" "$HOME/.ssh" 2>/dev/null | sort -u)
  [ "$found" -eq 0 ] && ok "chaves privadas protegidas ou inexistentes"

  head2 "cifra do disco e Secure Boot — nao automatizavel"
  if [ -s /etc/crypttab ] || lsblk -o FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
    ok "LUKS presente"
  else
    warn "RAIZ NAO CIFRADA. Nenhuma monitorizacao compensa um disco que sai"
    warn "da tua posse: chaves SSH, tokens, senhas do browser e dados de"
    warn "clientes ficam legiveis ao remover o SSD."
    say  "    caminhos: reinstalar com LUKS (seguro) · cryptsetup reencrypt"
    say  "    (no lugar, exige backup verificado e corrente) · ou LUKS apenas"
    say  "    numa particao nova para os dados sensiveis"
  fi
  if have mokutil; then
    local sb
    sb=$(mokutil --sb-state 2>/dev/null)
    grep -qi "enabled" <<<"$sb" && ok "Secure Boot activo" || warn "Secure Boot: $sb"
    grep -qi "setup mode" <<<"$sb" && warn "Setup Mode: o firmware aceita qualquer chave inscrita"
  fi

  head2 "AppArmor"
  if have aa-status; then
    local tot enf
    tot=$($SUDO aa-status 2>/dev/null | awk '/profiles are loaded/{print $1}')
    enf=$($SUDO aa-status 2>/dev/null | awk '/profiles are in enforce/{print $1}')
    say "  $enf de $tot perfis em enforce"
    [ "${enf:-0}" -lt "${tot:-1}" ] && warn "os restantes nao confinam nada"
  fi
}

# =============================================================================
# MONITOR — linha de base e diferenca. O que detecta um backdoor num portatil
# nao e um agente em tempo real: e comparar hoje com ontem.
# =============================================================================
BASELINE="$STATE_DIR/baseline"

# Uma base escrita sem sudo utilizavel fica INCOMPLETA em silencio, e o
# primeiro diff mostra mudancas falsas em massa — onde uma mudanca real passa
# despercebida. Mais vale nenhuma base do que uma base cega.
sudo_utilizavel() {
  [ "$(id -u)" -eq 0 ] && return 0
  $SUDO -n true 2>/dev/null && return 0
  return 1
}

snapshot_persistencia() {
  local out="$1"; mkdir -p "$(dirname "$out")"
  if ! sudo_utilizavel; then
    no "sudo nao utilizavel sem senha: a base ficaria incompleta e NAO foi escrita"
    warn "corre esta fase num terminal, onde o sudo pode pedir a senha:"
    say  "    ./toolchain.sh monitor --apply"
    return 1
  fi
  {
    echo "## portas a escutar"
    $SUDO ss -lntuH 2>/dev/null | awk '{print $1, $5}' | sort -u
    echo "## unidades systemd do sistema (nao-pacote)"
    $SUDO find /etc/systemd/system -maxdepth 2 \( -name '*.service' -o -name '*.timer' \) 2>/dev/null | sort
    echo "## unidades do utilizador"
    find "$HOME/.config/systemd/user" \( -name '*.service' -o -name '*.timer' \) 2>/dev/null | sort
    echo "## cron"
    $SUDO ls -1 /etc/cron.d /etc/cron.daily /etc/cron.hourly 2>/dev/null | sort -u
    crontab -l 2>/dev/null | grep -vE '^#|^$' | sort
    echo "## autostart"
    ls -1 "$HOME/.config/autostart" 2>/dev/null | sort
    echo "## udev local"
    ls -1 /etc/udev/rules.d 2>/dev/null | sort
    echo "## sudoers.d"
    $SUDO ls -1 /etc/sudoers.d 2>/dev/null | sort
    $SUDO grep -rhE '^[^#]' /etc/sudoers.d/ 2>/dev/null | sort
    echo "## ld.so.preload"
    cat /etc/ld.so.preload 2>/dev/null
    echo "## authorized_keys"
    cat "$HOME/.ssh/authorized_keys" 2>/dev/null | awk '{print $1, $3}'
    echo "## grupos do utilizador"
    id -nG | tr ' ' '\n' | sort
    echo "## binarios setuid"
    $SUDO find /usr /opt -xdev -perm -4000 -type f 2>/dev/null | sort
  } > "$out" 2>/dev/null
}

fase_monitor() {
  head2 "auditd: registar escritas nos pontos de persistencia"
  if ! have auditctl; then
    pkg auditctl auditd audit audit audit || warn "instala o auditd primeiro"
  fi
  if have auditctl; then
    local rf=/etc/audit/rules.d/99-toolchain.rules
    if [ -f "$rf" ]; then skip "regras ja instaladas"
    elif (( APPLY )); then
      $SUDO mkdir -p /etc/audit/rules.d
      # Vigiar os sitios onde um backdoor TEM de escrever, nao "tudo".
      # A ultima regra responde ao cenario mais provavel num portatil de
      # desenvolvimento: codigo de terceiros, executado por ti, a escalar.
      # Heredoc LITERAL (<<'EOF'): nada se expande dentro dele. O caminho do
      # home entra depois, por sed. Com <<EOF sem aspas, um backtick num
      # comentario e substituicao de comando — foi o que quebrou esta funcao a
      # 2026-11-22: `never` e `always` em prosa foram executados como comandos.
      $SUDO tee "$rf" >/dev/null <<'EOF'
-w /etc/systemd/system -p wa -k persist_systemd
-w /etc/cron.d -p wa -k persist_cron
-w /etc/sudoers -p wa -k persist_sudo
-w /etc/sudoers.d -p wa -k persist_sudo
-w /etc/pam.d -p wa -k persist_pam
-w /etc/ld.so.preload -p wa -k persist_preload
-w /usr/local/bin -p wa -k persist_localbin
-w /usr/local/sbin -p wa -k persist_localbin
-w __HOME__/.ssh -p wa -k persist_ssh
-w __HOME__/.config/systemd/user -p wa -k persist_user_units
-w __HOME__/.config/autostart -p wa -k persist_autostart

# As ferramentas de consulta do auditd geram entradas ao serem usadas: cada
# ausearch aparece no registo que esta a ler. Estas regras never vem ANTES da
# regra always de proposito, porque a primeira que casa decide.
-a never,exit -F arch=b64 -S execve -F exe=/usr/sbin/ausearch
-a never,exit -F arch=b64 -S execve -F exe=/usr/sbin/aureport
-a never,exit -F arch=b64 -S execve -F exe=/usr/sbin/auditctl

# Cada execucao como root a partir de uma sessao de utilizador.
#
# ATENCAO ao campo tty: NAO e uma assinatura fiavel de script de build.
# Medido nesta configuracao: contentores rootless produzem ~384 escaladas sem
# tty por dia (newuidmap/newgidmap, setuid root, invocados pelo podman), e
# qualquer ferramenta que corra sem terminal aparece igual. O tty separa
# "humano num terminal" de "todo o resto", e todo o resto inclui a tua
# infraestrutura normal.
#
# O que funciona e o CONJUNTO de nomes, comparado dia a dia:
#   ausearch -k root_exec -i -ts today | grep type=SYSCALL |
#     grep "tty=(none)" | grep -oE "comm=[^ ]+" | sort -u
# Um nome novo e o sinal. A contagem nao e.
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_exec
EOF
      $SUDO sed -i "s|__HOME__|$HOME|g" "$rf"
      revert_note "sudo rm -f $rf && sudo augenrules --load"
      $SUDO augenrules --load >/dev/null 2>&1 && $SUDO systemctl enable --now auditd >/dev/null 2>&1 \
        && ok "regras carregadas ($( $SUDO auditctl -l 2>/dev/null | wc -l ) activas)" || no "auditd"
      say "  consultar:  sudo ausearch -k persist_sudo -i | tail"
      say "              sudo ausearch -k root_exec -i | tail"
    else dry "/etc/audit/rules.d/99-toolchain.rules com 12 regras de persistencia + root_exec"; fi
  fi

  head2 "integridade dos ficheiros de pacotes"
  case "$(distro_family)" in
    debian) have debsums || pkg debsums debsums - - -
            if have debsums; then
              if (( APPLY )); then
                local n
                n=$($SUDO debsums -c 2>/dev/null | wc -l)
                [ "$n" -eq 0 ] && ok "nenhum ficheiro de pacote alterado" || warn "$n ficheiros alterados: sudo debsums -c"
              else dry "sudo debsums -c  (compara com os checksums do dpkg)"; fi
            fi ;;
    rhel)   if (( APPLY )); then
              local n
              n=$($SUDO rpm -Va --nomtime --nosize 2>/dev/null | grep -c '^..5') 
              [ "${n:-0}" -eq 0 ] && ok "nenhum ficheiro de pacote alterado" || warn "$n com checksum diferente: sudo rpm -Va"
            else dry "sudo rpm -Va --nomtime  (verificacao nativa do rpm)"; fi ;;
    arch)   have paccheck && { (( APPLY )) && run "paccheck" -- $SUDO paccheck --md5sum --quiet || dry "paccheck --md5sum"; } \
              || warn "pacutils (paccheck) da a verificacao equivalente no Arch" ;;
  esac

  head2 "linha de base da superficie de persistencia"
  # Isto e o nucleo: um inventario guardado e comparado. Um backdoor tem de
  # escrever em algum destes sitios para sobreviver a um reboot.
  if (( APPLY )); then
    mkdir -p "$BASELINE"
    local novo
    novo="$BASELINE/snapshot-$(date +%Y%m%d-%H%M%S).txt"
    if ! snapshot_persistencia "$novo"; then rm -f "$novo"; return 1; fi
    local ant
    ant=$(find "$BASELINE" -name 'snapshot-*.txt' ! -name "$(basename "$novo")" 2>/dev/null | sort | tail -1)
    if [ -z "$ant" ]; then
      ok "primeira linha de base: $(wc -l < "$novo") entradas em $novo"
      warn "a base inicial so vale se a maquina estiver limpa AGORA. Guarda uma"
      warn "copia fora da maquina: um atacante com root reescreve a base local."
    else
      local d
      d=$(diff "$ant" "$novo" | grep -cE '^[<>]')
      if [ "$d" -eq 0 ]; then ok "sem alteracoes desde $(basename "$ant")"
      else
        warn "$d linhas mudaram desde $(basename "$ant"):"
        diff "$ant" "$novo" | grep -E '^[<>]' | head -20 | sed 's/^/    /'
        say  "    completo:  diff $ant $novo"
      fi
    fi
  else dry "snapshot de portas, unidades, cron, autostart, udev, sudoers, setuid, grupos — e diff com o anterior"; fi

  head2 "timer diario da comparacao"
  local ud="$HOME/.config/systemd/user"
  if [ -f "$ud/toolchain-monitor.timer" ]; then skip "timer ja existe"
  elif (( APPLY )); then
    mkdir -p "$ud"
    cat > "$ud/toolchain-monitor.service" <<EOF
[Unit]
Description=toolchain monitor — diferenca da superficie de persistencia

[Service]
Type=oneshot
Nice=19
ExecStart=$PWD/toolchain.sh monitor --apply
EOF
    cat > "$ud/toolchain-monitor.timer" <<'EOF'
[Unit]
Description=Compara a superficie de persistencia uma vez por dia

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    revert_note "systemctl --user disable --now toolchain-monitor.timer && rm -f $ud/toolchain-monitor.{service,timer}"
    systemctl --user daemon-reload && systemctl --user enable --now toolchain-monitor.timer \
      && ok "timer diario activo" || no "timer de monitorizacao"
  else dry "timer de utilizador diario a correr 'toolchain.sh monitor --apply'"; fi

  head2 "o que NAO instalo, e porque"
  say "  rkhunter / chkrootkit — procuram assinaturas de rootkits antigos, dao"
  say "    muitos falsos positivos com contentores e snaps, e nao encontram"
  say "    nada que a linha de base acima nao encontre melhor."
  say "  Falco / Tetragon — excelentes num cluster, onde a carga e homogenea."
  say "    Numa estacao de trabalho produzem ruido constante e acabam ignorados."
  say "    Monitorizacao ignorada e pior que nenhuma: da sensacao de cobertura."
  say "  antivirus — num Linux de desenvolvimento encontra sobretudo malware de"
  say "    Windows em anexos; nao cobre codigo de build nem disco roubado."
}

# =============================================================================
# SELFTEST — exercita o que o dry-run NAO alcanca.
#
# A matriz de CI corre todas as fases em dry-run, o que valida que o script
# corre em cada familia de distro. Mas tudo o que esta dentro de `(( APPLY ))`
# fica sem teste — e foi exactamente la que viveu o unico bug que chegou a
# producao: um backtick num comentario dentro de um heredoc `<<EOF` sem aspas,
# que o shell executou como comando. O shellcheck nao o apanha (e sintaxe
# valida) e o dry-run nunca o alcanca.
#
# Esta fase valida o CONTEUDO gerado, sem o aplicar.
# =============================================================================
fase_selftest() {
  local falhas=0

  head2 "heredocs: nenhum conteudo literal deve conter expansao de shell"
  # Um heredoc <<'EOF' e literal e seguro. Um <<EOF expande $, ` e \ — e um
  # comentario em prosa com backticks passa a ser codigo.
  # Um <<EOF sem aspas e legitimo quando se QUER expandir $HOME ou $PWD. O
  # perigo e o CONTEUDO: um backtick ou um $( ) em prosa passa a ser executado.
  # Um teste que sinalize todos os <<EOF e ruido, e ruido e ignorado.
  local mau
  mau=$(awk '
    /<<EOF[[:space:]]*$/ { dentro=1; inicio=NR; achou=0; next }
    dentro && /^EOF$/ { if (achou) print inicio; dentro=0; next }
    dentro && (/`/ || /\$\(/) { achou=1 }
  ' "$0")
  if [ -n "$mau" ]; then
    local ln
    for ln in $mau; do no "heredoc <<EOF na linha $ln contem backtick ou \$( ) — sera EXECUTADO"; done
    falhas=$((falhas+1))
  else
    ok "nenhum heredoc expansivel com backtick ou \$( ) no conteudo"
    local n_exp
    n_exp=$(grep -cE "<<EOF[[:space:]]*$" "$0" || true)
    [ "${n_exp:-0}" -gt 0 ] && say "    ($n_exp heredocs <<EOF expandem de proposito: \$HOME, \$PWD nas unidades)"
  fi

  head2 "regras do auditd: conteudo renderizado"
  local tmp
  tmp=$(mktemp)
  sed -n "/tee \"\\\$rf\" >\/dev\/null <<'EOF'/,/^EOF\$/p" "$0" | sed '1d;$d' | sed "s|__HOME__|$HOME|g" > "$tmp"
  local nregras nperigo nhome
  nregras=$(grep -cE '^-[wa] ' "$tmp" || true)
  nperigo=$(grep -cE '[`$]' "$tmp" || true)
  nhome=$(grep -c "$HOME" "$tmp" || true)
  [ "${nregras:-0}" -ge 15 ] && ok "$nregras regras renderizadas" || { no "so $nregras regras (esperadas >=15)"; falhas=$((falhas+1)); }
  [ "${nperigo:-0}" -eq 0 ] && ok "sem backticks nem \$ no conteudo" || { no "$nperigo linhas com backtick ou \$ — serao executadas"; falhas=$((falhas+1)); }
  [ "${nhome:-0}" -ge 3 ] && ok "$nhome caminhos do home resolvidos" || { no "placeholder __HOME__ nao substituido"; falhas=$((falhas+1)); }
  # A ordem importa: as regras `never` TEM de vir antes da `always`.
  local l_never l_always
  l_never=$(grep -n 'never,exit' "$tmp" | tail -1 | cut -d: -f1)
  l_always=$(grep -n 'always,exit' "$tmp" | head -1 | cut -d: -f1)
  if [ -n "$l_never" ] && [ -n "$l_always" ] && [ "$l_never" -lt "$l_always" ]; then
    ok "regras never antes da always (a primeira que casa decide)"
  else no "ordem das regras errada: never na linha ${l_never:-?}, always na ${l_always:-?}"; falhas=$((falhas+1)); fi
  rm -f "$tmp"

  head2 "unidades systemd geradas: sintaxe"
  local u
  for u in cargo-sweep toolchain-monitor; do
    sed -n "/cat > \"\\\$ud\/$u.service\"/,/^EOF\$/p" "$0" | grep -qE '^\[Unit\]|^\[Service\]' \
      && ok "$u.service tem as seccoes obrigatorias" \
      || { no "$u.service sem [Unit]/[Service]"; falhas=$((falhas+1)); }
  done

  head2 "run(): a descricao nunca entra no comando"
  grep -qE 'run\(\) \{\s*$' "$0" && grep -A3 'run() {' "$0" | grep -q 'shift' \
    && ok "run() descarta a descricao antes de executar" \
    || { no "run() pode executar a descricao como comando"; falhas=$((falhas+1)); }

  say ""
  [ "$falhas" -eq 0 ] && ok "selftest: tudo passou" || { no "selftest: $falhas verificacoes falharam"; return 1; }
}

# =============================================================================
# DESPACHO
# =============================================================================
say "toolchain.sh — fase: $PHASE $( (( APPLY )) && echo '[APLICAR]' || echo '[DRY-RUN]')"
say "log: $LOG"

RC=0
case "$PHASE" in
  doctor)  fase_doctor || RC=$? ;;
  os)      fase_os || RC=$? ;;
  rust)    fase_rust "$@" ;;
  go)      fase_go || RC=$? ;;
  python)  fase_python || RC=$? ;;
  node)    fase_node || RC=$? ;;
  k8s)     fase_k8s || RC=$? ;;
  iac)     fase_iac || RC=$? ;;
  sec)     fase_sec || RC=$? ;;
  obs)     fase_obs || RC=$? ;;
  cli)     fase_cli || RC=$? ;;
  selftest) fase_selftest || RC=$? ;;
  harden)  fase_harden || RC=$? ;;
  monitor) fase_monitor || RC=$? ;;
  delonix) fase_delonix || RC=$? ;;
  all)
    # O delonix fica DE FORA do `all` de proposito: mexe em subuid/subgid,
    # AppArmor e politica de seguranca do host, e isso merece uma decisao
    # explicita, nao vir a reboque de um "instala tudo".
    fase_os; fase_rust "$@"; fase_go; fase_python; fase_node
    fase_k8s; fase_iac; fase_sec; fase_obs; fase_cli
    fase_harden; fase_monitor
    say ""; say "Delonix NAO instalado: corre './toolchain.sh delonix --apply' a parte."
    ;;
  -h|--help|help)
    sed -n '2,45p' "$0"; exit 0 ;;
  *)
    say "fase desconhecida: $PHASE"
    say "fases: doctor selftest os rust go python node k8s iac sec obs cli harden monitor delonix all"
    exit 2 ;;
esac

say ""
say "────────────────────────────────────────────────────────"
if (( APPLY )); then
  say "aplicado. log: $LOG"
  [ -s "$STATE_DIR/revert.log" ] && say "para reverter mudancas de sistema: $STATE_DIR/revert.log"
else
  say "DRY-RUN: nada foi alterado."
  say "para executar:  $0 $PHASE --apply"
fi

# Propagar a falha. Sem isto o script acaba sempre em `say`, sai 0, e um teste
# que FALHOU deixa a CI verde — o pior resultado possivel num gate.
# Encontrado a 2026-11-22 pelo proprio selftest.
[ "$RC" -ne 0 ] && say "" && say "fase $PHASE terminou com falhas (exit $RC)"
exit "$RC"
