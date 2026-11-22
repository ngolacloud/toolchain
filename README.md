# toolchain

[![ci](https://github.com/ngolacloud/toolchain/actions/workflows/ci.yml/badge.svg)](https://github.com/ngolacloud/toolchain/actions/workflows/ci.yml)

Script de provisionamento para estações de trabalho de **DevOps, Platform
Engineering e SRE**, e para ambientes de desenvolvimento em **Rust, Go, Python
e Node.js**.

Não é uma lista de `apt install`. Cada ajuste de sistema que o script aplica
traz, em comentário, a medição que o justifica e o incidente que o ensinou.
Onde uma recomendação comum está errada, o script diz porquê e não a aplica.

```bash
git clone https://github.com/ngolacloud/toolchain
cd toolchain
./toolchain.sh doctor            # inventário: o que está, o que falta, o que está mal
./toolchain.sh os                # DRY-RUN — mostra o que faria
./toolchain.sh os --apply        # executa
```

**Nada muda sem `--apply`.** Todas as fases correm em dry-run por omissão.

## Distribuições suportadas

Detecção por `ID` e `ID_LIKE` do `/etc/os-release`:

| família | gestor | distribuições |
|---|---|---|
| Debian | `apt` | Debian, Ubuntu, Zorin, Mint, Pop!_OS, elementary |
| Red Hat | `dnf` | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux |
| Arch | `pacman` | Arch, Manjaro, EndeavourOS, Garuda |
| SUSE | `zypper` | openSUSE Leap, Tumbleweed, SLES |

### O que a CI verifica, e o que não verifica

A matriz corre as **11 fases em dry-run** em `ubuntu:24.04`, `debian:12`,
`fedora:41`, `rockylinux:9` e `archlinux:latest`, com a saída de cada fase
visível no log. Isso prova que o script corre nas quatro famílias, que a
detecção por `ID`/`ID_LIKE` acerta, e que a tabela resolve um nome de pacote
para cada binário — no Arch, por exemplo, sem um único "sem pacote em".

O que **não** prova: o dry-run não instala. Um nome que exista mas aponte para
o pacote errado só se descobre a instalar. Se encontrares um, o `run()` falha
alto e o PR é bem-vindo.

### Nomes de pacote e de binário

Os nomes de pacote diferem entre famílias, e os nomes dos **binários** também.
No Debian, `fd-find` instala `/usr/bin/fdfind` e `bat` instala `/usr/bin/batcat`
por conflito de nomes — o script cria os links e verifica o binário real, não o
nome do pacote. Em Fedora e Arch os mesmos pacotes instalam `fd` e `bat`.

Nas distribuições Red Hat empresariais (RHEL, Rocky, Alma) várias ferramentas
vivem no **EPEL**. O script detecta-o e avisa, mas não acrescenta repositórios
de terceiros sozinho: isso é decisão de quem administra a máquina.

No Arch e Manjaro, muitas ferramentas só existem no **AUR**. O script usa
`paru` ou `yay` se já estiverem instalados, e caso contrário indica o pacote.
Não instala um helper de AUR por iniciativa própria, nem compila pacotes do AUR
sem o utilizador saber.

---

## Fases

### `doctor` — diagnóstico, não muda nada

A primeira coisa a correr numa máquina nova. Imprime:

- distribuição, kernel, gestor de pacotes, CPU, RAM, alimentação
- quais optimizações de SO estão aplicadas e quais faltam
- serviços candidatos a desligar, **já verificados quanto a uso real**
- tempo de arranque e unidades em falha
- versões de Rust, Go, Python, Node e dos gestores
- inventário das ferramentas: presentes e em falta
- estado do Delonix Runtime

O `doctor` só reconhece **binários no `PATH`**, nunca funções nem aliases de
shell. Um diagnóstico que herda o ambiente de quem o chama mente sobre a
máquina: num teste real, um inventário interactivo deu `rg` como presente
quando era uma função injectada pelo ambiente e o ripgrep não estava instalado.

### `os` — optimizações de sistema

Cada uma com a sua razão medida.

| ajuste | porquê |
|---|---|
| `journald SystemMaxUse=500M` | sem tecto o default é 10% do disco — 93 GB num disco de 1 TB |
| `vm.vfs_cache_pressure=50` | com `buff/cache` grande e árvores de build enormes, manter dentries e inodes em memória dá ganho medível |
| `vm.swappiness=10` | o swap é almofada para picos do linker, não memória de trabalho |
| `fs.inotify.max_user_watches=1048576` | watchers de ficheiros em monorepos esgotam o default com facilidade |
| `noatime` na raiz | builds com milhares de ficheiros pequenos escrevem `atime` a cada leitura |
| Docker `log-opts max-file` | um contentor esquecido escreve logs até encher o disco |
| perfil de desempenho só com carregador | ver a secção de energia |
| timer semanal de `cargo-sweep` | ver a secção de cache |
| `sccache` com tecto de 10 GiB | uma cache sem tecto deixa de ser cache |

**O que o script NÃO faz, e porquê.** Muitos guias mandam desligar `cups`,
`avahi-daemon` e `ModemManager` em bloco. O script testa cada um antes:

- `cups` e `avahi-daemon` ficam se `lpstat -p` encontrar impressoras —
  impressoras de rede descobrem-se por mDNS, e desligar o avahi parte-as
- `ModemManager` só sai se `mmcli -L` não encontrar modem nenhum
- `systemd-networkd` só sai se não gerir interface nenhuma e não tiver
  configuração própria em `/etc/systemd/network`

Essa última vale 2 minutos de arranque numa máquina onde o NetworkManager é
quem manda: a espera `systemd-networkd-wait-online` esgota o timeout em cada
boot, sem gerir nada.

O `/etc/docker/daemon.json` é **fundido**, nunca sobrescrito. Um `echo >` nesse
ficheiro apaga runtimes registados — num caso real, o runtime `nvidia`, o que
teria partido todos os contentores com GPU.

### `rust`

`rustup` com `clippy`, `rustfmt`, `rust-analyzer`, `rust-src` e `llvm-tools`.
Targets de cross-compilação: `x86_64-unknown-linux-musl`,
`aarch64-unknown-linux-musl` e `x86_64-pc-windows-gnu`, com os linkers
correspondentes (`mingw-w64`, `musl-gcc`).

Ferramentas: `cargo-nextest`, `cargo-deny`, `cargo-audit`, `cargo-sweep`,
`cargo-cyclonedx`, `cargo-machete`, `cargo-outdated`, `cargo-expand`,
`sccache`, `cross`.

**Perfis de build.** O script imprime os perfis recomendados, medidos num
workspace Rust de 9 membros com 514 crates no lockfile:

```
base                                 2840 MB
debug = "line-tables-only"           1984 MB   −30%
+ [profile.dev.package."*"] debug=0  1513 MB   −47%
```

A segunda alavanca tira a informação de depuração às **dependências** e
mantém-na no teu código. Num workspace onde o lockfile tem 514 crates para 9
membros, é onde está a maior parte do peso.

Dois avisos que o script dá e que convém levar a sério:

- **não pôr `strip` no perfil `release`.** Um binário despido torna um core
  dump de produção ilegível. O `strip` pertence a um perfil `dist`, usado
  depois de extrair os símbolos para ficheiro separado com `objcopy`.
- **não definir `CARGO_TARGET_DIR` global.** Quebra qualquer script que
  dependa de `./target/release/<bin>`, e o cargo já separa por triple quando se
  usa `--target`.

Sobre **macOS**: o SDK da Apple só pode ser usado em hardware Apple, por
licença. O script não monta `osxcross` nem `cargo-zigbuild` com um SDK
descarregado. A saída defensável é um runner macOS no CI.

### `go`

Go do **tarball oficial**, não do pacote da distribuição: as distros ficam uma
ou duas versões atrás, e um projecto que use toolchains recentes tropeça nisso.

Ferramentas: `gopls`, `dlv`, `govulncheck`, `mockgen`, `golangci-lint`.

### `python`

`uv` como gestor de Python, pacotes e ferramentas — substitui `pip`, `venv`,
`pyenv` e `pipx` numa só ferramenta, com resolução uma ordem de grandeza mais
rápida.

Ferramentas instaladas com `uv tool install`, cada uma no seu ambiente:
`ruff`, `mypy`, `pre-commit`, `ansible-lint`, `checkov`.

**Nunca `pip install --user`** num sistema moderno: o PEP 668 marca o Python do
sistema como gerido externamente, e furar isso parte actualizações.

### `node`

Node via `nvm` (LTS), `pnpm` activado por `corepack` — que fixa a versão do
gestor por projecto através do campo `packageManager`, tornando os builds
reproduzíveis. Mais `biome` (lint e format numa ferramenta) e `typescript`.

### `k8s`

`kubectl`, `kustomize`, `helm`, `k9s`, `kubectx`/`kubens`, `stern`, `kind`,
`kubeconform`.

O `flux` e o `argocd` **não** são instalados: ter as duas CLIs de GitOps sem
usar nenhuma é superfície e confusão. Instala a do controlador que usas.

### `iac`

**OpenTofu** em vez de Terraform — fork sob a Linux Foundation depois da
mudança de licença da HashiCorp para BUSL. Mais `terragrunt`, `tflint`,
`packer`, `ansible`, `ansible-lint`, `checkov`.

### `sec`

`grype` e `syft` (SBOM e scan), `cosign` (assinatura sigstore), `sops` e `age`
(segredos cifrados em git, com chaves modernas em vez de GPG), `skopeo`,
`buildah`, `dive`, `hadolint`.

**Nada se instala sem checksum verificado.** Quando não há pacote da
distribuição nem `go install`, o script usa releases do GitHub — e a função
`gh_bin` resolve o asset pela API do GitHub e **recusa-se a instalar** se o upstream não publicar um ficheiro de
checksums, ou se o `sha256` não bater.

Resolver o asset pela API importa: `releases/latest/download/<nome-fixo>` só
funciona se o nome do asset não incluir a versão. Em várias ferramentas inclui,
e o download dá 404 — três falhas que parecem problema de rede e são URL errado. Duas recusas visíveis valem mais do que
duas instalações silenciosas de origem não verificada.

O `trivy` e o `vault` ficam com um aviso em vez de instalação: exigem
acrescentar repositórios de terceiros ao sistema, e isso é decisão de quem
administra a máquina.

### `obs`

`k6` (carga com scripts em JS), `oha` (hey/ab moderno em Rust), `promtool`,
`amtool`, `sysstat` (o `sar` dá histórico de desempenho, essencial em SRE),
`bpftrace`, `iperf3`, `mtr`.

### `cli`

`jq`, `yq`, `fd`, `ripgrep`, `bat`, `delta`, `btop`, `duf`, `dust`, `just`,
`direnv`, `zoxide`, `lazygit`, `gh`.

### `harden` — fundações de segurança

Sem estas, monitorizar é observar a porta aberta.

| verificação | porquê |
|---|---|
| `NOPASSWD:ALL` no sudo | um `build.rs` de crate, um `postinstall` de npm ou um `go generate` correm com a tua identidade. Com `NOPASSWD`, correm `sudo` sem prompt |
| grupo `docker` | quem está nele monta `/` num contentor; é equivalente a root por outra via |
| `ufw` realmente activo | `systemctl is-enabled ufw` dizer `enabled` **não** significa que o firewall esteja a filtrar |
| chaves SSH sem passphrase | detectadas pelo **conteúdo** (cabeçalho PEM/OpenSSH), não pelo nome: `id_*` deixa passar as outras |
| cifra do disco | reportado, não automatizado |
| Secure Boot e Setup Mode | reportado, não automatizado |
| AppArmor em enforce | quantos perfis confinam de facto |

A regra `NOPASSWD` é **comentada**, não apagada, e o ficheiro é validado com
`visudo -c` antes de se confiar nela — se reprovar, restaura do backup. Antes
de activar o `ufw`, permite-se a entrada em `lo` e em cada ponte encontrada,
senão as VMs e os contentores perdem DHCP e DNS.

Melhor do que filtrar é não expor: um serviço a escutar em `127.0.0.1` em vez
de `0.0.0.0` remove a exposição na origem.

### `monitor` — linha de base e diferença

O que detecta um backdoor num portátil não é um agente em tempo real: é
**comparar hoje com ontem**.

**`auditd` nos pontos onde um backdoor tem de escrever** para sobreviver a um
reboot — unidades systemd do sistema e do utilizador, `cron.d`, `sudoers.d`,
`pam.d`, `ld.so.preload`, `/usr/local/bin`, `~/.ssh`, `~/.config/autostart` —
mais uma regra que registra cada `execve` como root a partir de uma sessão de
utilizador. É essa última que cobre o cenário mais provável: código de
terceiros, executado por ti, a escalar.

```bash
sudo ausearch -k persist_sudo -i -ts today
```

O campo que torna a regra `root_exec` útil é o **`tty`**. Uma escalada que tu
fizeste tem um terminal associado (`tty=pts4`); um `build.rs` de crate ou um
`postinstall` de npm a chamar `sudo` corre **sem terminal** e aparece como
`tty=(none)`. É essa a assinatura do cenário mais provável:

```bash
sudo ausearch -k root_exec -i -ts today | grep type=SYSCALL | grep 'tty=(none)' | grep -oE 'comm=\S+' | sort | uniq -c | sort -rn
```

Num dia normal devolve nada, ou só serviços do sistema.

As ferramentas de consulta do auditd geram entradas ao serem usadas — cada
`ausearch` aparece no registo que está a ler. O conjunto de regras exclui
`ausearch`, `aureport` e `auditctl` com regras `never` colocadas **antes** da
`always`: a primeira que casa decide.

**Integridade dos ficheiros de pacotes**, com a ferramenta nativa de cada
família: `debsums -c` no Debian, `rpm -Va` no Red Hat, `paccheck --md5sum` no
Arch.

**Inventário comparado**: portas a escutar, unidades systemd, cron, autostart,
regras udev, `sudoers.d`, binários setuid e grupos do utilizador. Guardado em
`~/.local/state/toolchain/baseline/` e comparado com o anterior, com um timer
de utilizador diário.

A primeira base só vale se a máquina estiver limpa no momento em que é criada,
e **uma cópia deve viver fora da máquina**: um atacante com root reescreve a
base local.

### O que estas fases não instalam, e porquê

- **`rkhunter` e `chkrootkit`** procuram assinaturas de rootkits antigos, dão
  muitos falsos positivos com contentores e snaps, e não encontram nada que a
  linha de base não encontre melhor.
- **Falco ou Tetragon** são excelentes num cluster, onde a carga é homogénea.
  Numa estação de trabalho produzem ruído constante e acabam ignorados — e
  monitorização ignorada é pior que nenhuma, porque dá sensação de cobertura.
- **Antivírus**: num Linux de desenvolvimento encontra sobretudo malware de
  Windows em anexos. Não cobre código de build nem disco roubado.

### `delonix`

Instala o **Delonix Runtime** — motor de contentores e VMs.

O script **não reimplementa** a instalação: o Delonix tem um instalador oficial
que detecta a distribuição, instala todas as dependências de runtime de
contentores *e* de VMs, configura `subuid`/`subgid` e AppArmor para o modo
rootless, e trata do CDI da NVIDIA, do `cloud-hypervisor` e do firmware EDK2.
Esta fase localiza-o e chama-o.

```bash
DELONIX_FLAGS="--with-cri --production" ./toolchain.sh delonix --apply
```

Flags úteis: `--with-cri` (nó Kubernetes), `--production` (tuning de escala),
`--no-vm` (só contentores), `--user` (binário em `~/.local/bin`).

Esta fase fica **fora do `all`** de propósito: mexe em política de segurança do
host, e isso merece uma decisão explícita em vez de vir a reboque de um
"instala tudo".

---

## Energia: a parte que os guias esquecem

Num portátil, um perfil de desempenho aplicado no arranque e mantido com
`RemainAfterExit=yes` fixa `EPP=performance` **também em bateria**. Medido:
cerca de 8,5 W a mais em carga leve.

O script resolve isto com duas peças que só funcionam juntas:

```ini
# override da unidade
[Unit]
ConditionACPower=true
```

```
# regra udev, para a transição em tempo real
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/usr/bin/systemctl --no-block start <unidade>"
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/usr/bin/systemctl --no-block stop <unidade>"
```

A condição do systemd só é avaliada quando algo tenta arrancar a unidade — é a
regra udev que torna isto dinâmico. O override sozinho aplicaria o perfil
apenas no arranque, e nunca ao ligar o cabo a seguir.

As fases que **compilam** (`rust`, e parte de `go` e `cli`) verificam a
alimentação e param com um aviso se a máquina estiver em bateria. Quatro builds
Rust a frio puseram um portátil a 110 W e reduziram a autonomia a 25 minutos.
Passa `--mesmo-em-bateria` para insistir.

---

## Cache: porque é que os `target/` chegam a 190 GB

Três mecanismos, e nenhum deles é "apagar de vez em quando".

**1. Perfis que produzem menos.** Os −47% da secção `rust`.

**2. Tecto por directório, não por idade.** O `cargo-sweep --time N` só poda
gerações **substituídas**: num `target/` com uma só geração devolve 0 B. O que
funciona é um tecto rígido:

```
cargo-sweep sweep --hidden --recursive --installed  <dirs>   # artefactos de toolchains removidas
cargo-sweep sweep --hidden --recursive --maxsize 4GB <dirs>  # tecto por target/
```

O `--hidden` é indispensável: sem ele o `--recursive` salta directórios que
começam por ponto, e é exactamente em `.worktrees/` que os `target/` se
acumulam. Num caso real eram 48 GB invisíveis ao sweep.

O `--installed` ganhou importância depois de remover toolchains: os artefactos
compilados por uma toolchain que já não existe ficam a ocupar espaço em cada
`target/` que a usou. Numa máquina real, 317 MiB num único projecto.

**3. Vigiar a soma, não só cada directório.** O tecto é por `target/`. Com N
workspaces × M triples, o pior caso multiplica-se:

```bash
find ~/workspace ~/workspaces -type d -name target -prune \
  -exec du -xsm {} + | awk '{s+=$1} END {printf "%.1f GB\n", s/1024}'
```

---

## Princípios

Oito, cada um vindo de um erro concreto. Estão no cabeçalho do script, e o
script implementa-os em vez de os descrever.

1. **Dry-run por omissão.** Nada muda sem `--apply`.
2. **Falhar alto.** Um passo que falha imprime `!! FALHOU` com o exit code. A
   descrição de um passo nunca entra no comando — numa versão anterior, uma
   função `run()` com esse bug executava a descrição como se fosse o comando, e
   quatro passos falharam em silêncio durante uma hora.
3. **Nunca sobrescrever configuração.** JSON, TOML e YAML são fundidos, com
   backup.
4. **Verificar antes de desligar.** Cada serviço é testado quanto a uso real.
5. **Inventariar antes de apagar.** Um `prune --volumes` apagou um volume
   nomeado de uma base de dados de desenvolvimento, porque a ferramenta só
   mostrava um total agregado.
6. **O log não vive onde o script apaga.** Fica em
   `~/.local/state/toolchain/`.
7. **Olhar para o alvo, não para os metadados.** `ls -1` segue symlinks;
   `nvidia-smi` acorda a GPU que se está a medir; o `Installed-Size` de um
   pacote já removido não é espaço em disco.
8. **Não compilar em bateria.**

## Reverter

Cada mudança de sistema escreve o comando que a desfaz:

```bash
cat ~/.local/state/toolchain/revert.log
```

## Licença

Apache-2.0
