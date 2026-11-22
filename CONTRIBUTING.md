# Contribuir

## O critério para um ajuste entrar no script

Um ajuste de sistema só entra se vier com **a medição que o justifica**. Não
chega dizer que "melhora o desempenho": precisa do número, do método e da
máquina onde foi medido, em comentário ao lado do código.

Se a medição não existir, o ajuste fica de fora. Se contradisser uma
recomendação comum, melhor ainda — mas então o comentário explica a contradição.

## O critério para uma ferramenta entrar

Por ordem de preferência na forma de instalar:

1. gestor de pacotes da distribuição — assinado, actualiza com o sistema
2. `go install` — compila da fonte, sem binários opacos
3. `uv tool install` — ferramentas Python, isoladas
4. release do GitHub — **último recurso**, e só com `sha256` verificado contra
   o ficheiro de checksums publicado pelo upstream

Uma ferramenta que exija acrescentar um repositório de terceiros ao sistema
**não** é instalada automaticamente: o script avisa e aponta a documentação.
Acrescentar fontes de pacotes é decisão de quem administra a máquina.

## Novas distribuições

A detecção é por `ID` e `ID_LIKE` do `/etc/os-release`. Para acrescentar uma
família, o que é preciso é:

- o mapa de nomes de pacote, que diferem entre famílias
- o mapa de nomes de **binário**, que também diferem: no Debian o pacote
  `fd-find` instala `/usr/bin/fdfind`
- correr `./toolchain.sh doctor` e `./toolchain.sh <fase>` (dry-run) nessa
  distribuição e colar a saída no PR

## Testar

Todas as fases têm de passar em dry-run sem erros:

```bash
for f in doctor os rust go python node k8s iac sec obs cli delonix; do
  ./toolchain.sh "$f" >/dev/null 2>&1 || echo "FALHOU: $f"
done
shellcheck -S warning toolchain.sh
```
