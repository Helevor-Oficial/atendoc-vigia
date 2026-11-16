#!/usr/bin/env bash
# Testes do vigia sem sair para a internet (MSF-615 e MSF-617).
#
# Tira do workflow o script do passo que testa (o bloco "run: |") e roda esse
# script contra um servidor HTTPS local que imita as respostas do Atendoc
# (teste/servidor.py). O curl e o openssl do script passam por dois
# invólucros que mandam toda conexão para o servidor local: nenhum pedido sai
# para a produção nem para o staging.
#
# Uso:
#   teste/rodar.sh                      todos os cenários, em paralelo
#   teste/rodar.sh hoje queda-502       só alguns cenários
#   teste/rodar.sh -w outro/vigia.yml   outro workflow com o mesmo formato
#                                       (o vigia.yml manual do atendoc-gitops)
#   PORTA_BASE=19443 teste/rodar.sh     outras portas locais (uma por cenário)
#
# O laço espera 1 minuto entre as rodadas, como no GitHub: o teste inteiro
# leva uns 3 minutos.
#
# Cenários (só a tela ou o /saude da produção mudam; o resto responde como hoje):
#   hoje                     / redireciona (307) para /entrar, que responde 200: sem alarme
#   queda-502                a tela responde 502: alarme da tela em até 3 minutos
#   sem-resposta             a tela não responde em 15 s: alarme da tela em até 3 minutos
#   redirecionamento-errado  a tela redireciona para outro lugar: alarme (3xx não conta como no ar)
#   certificado              certificado a 5 dias de vencer: alarme de certificado
#   armazenamento-503        /saude 503 só com o armazenamento sem resposta: aviso, sem alarme
#   armazenamento-limiar     o mesmo, com o limiar do armazenamento baixado de 15 para 2
#                            minutos no script: alarme próprio do armazenamento (só no
#                            vigia em laço, o que usa MINUTOS)
#   banco-503                /saude 503 com o banco sem resposta: alarme da API em até 3 minutos
#   saude-sem-json           /saude 503 sem o JSON (o proxy sem a API): alarme da API em até 3 minutos

set -uo pipefail

aqui=$(cd "$(dirname "$0")" && pwd)
workflow="$aqui/../.github/workflows/vigia.yml"
if [ "${1:-}" = "-w" ]; then
  workflow=$2
  shift 2
fi
cenarios=("$@")
LIMITE_ALARME=180

py=""
for candidato in python3 python; do
  if command -v "$candidato" >/dev/null 2>&1 && "$candidato" -c 'import ssl' >/dev/null 2>&1; then
    py=$candidato
    break
  fi
done
[ -n "$py" ] || { echo "precisa de python 3 com ssl"; exit 2; }
curl_real=$(command -v curl)
openssl_real=$(command -v openssl)

trabalho=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; [ -n "${MANTER:-}" ] || rm -rf "$trabalho"' EXIT

# O script do passo, sem o recuo do YAML.
PYTHONIOENCODING=utf-8 "$py" - "$workflow" "$trabalho/vigia.sh" <<'PY' || exit 2
import re, sys
linhas = open(sys.argv[1], encoding="utf-8").read().splitlines()
for i, linha in enumerate(linhas):
    m = re.match(r"^(\s*)run: \|\s*$", linha)
    if not m:
        continue
    base = len(m.group(1))
    bloco = []
    for x in linhas[i + 1:]:
        if x.strip() and len(x) - len(x.lstrip()) <= base:
            break
        bloco.append(x)
    recuo = min(len(x) - len(x.lstrip()) for x in bloco if x.strip())
    script = "\n".join(x[recuo:] for x in bloco) + "\n"
    if "${{" in script:
        sys.exit("o script usa expressão do GitHub (${{ }}), que o teste não sabe trocar")
    open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(script)
    sys.exit(0)
sys.exit("sem bloco 'run: |' no workflow")
PY

# Vigia em laço (o agendado) ou de uma passada só (o manual do gitops).
laco=""
grep -q 'MINUTOS' "$trabalho/vigia.sh" && laco=1
if [ "${#cenarios[@]}" -eq 0 ]; then
  cenarios=(hoje queda-502 sem-resposta redirecionamento-errado certificado
    armazenamento-503 banco-503 saude-sem-json)
  [ -n "$laco" ] && cenarios+=(armazenamento-limiar)
fi

rodar_cenario() {
  local cenario=$1 porta=$2
  local dir="$trabalho/$cenario"
  mkdir -p "$dir/bin"

  local dias=365 cenario_servidor=$cenario script="$trabalho/vigia.sh"
  if [ "$cenario" = certificado ]; then
    dias=5
    cenario_servidor=hoje
  fi
  if [ "$cenario" = armazenamento-limiar ]; then
    cenario_servidor=armazenamento-503
    script="$dir/vigia.sh"
    if ! grep -q '^MINUTOS_ARMAZENAMENTO_PARA_ALERTA=15$' "$trabalho/vigia.sh"; then
      printf '%s\tfalhou\t-\t-\to workflow não tem o limiar do armazenamento (MINUTOS_ARMAZENAMENTO_PARA_ALERTA=15)\n' \
        "$cenario" >"$dir/veredito"
      return
    fi
    sed 's/^MINUTOS_ARMAZENAMENTO_PARA_ALERTA=15$/MINUTOS_ARMAZENAMENTO_PARA_ALERTA=2/' "$trabalho/vigia.sh" >"$script"
  fi
  # MSYS2_ARG_CONV_EXCL: no Git Bash do Windows, o "/CN=" não vira caminho.
  MSYS2_ARG_CONV_EXCL="/CN=" "$openssl_real" req -x509 -newkey rsa:2048 -nodes -days "$dias" \
    -subj "/CN=atendoc-teste" -keyout "$dir/chave.pem" -out "$dir/certificado.pem" >/dev/null 2>&1

  PYTHONIOENCODING=utf-8 "$py" "$aqui/servidor.py" "$porta" "$dir/certificado.pem" "$dir/chave.pem" \
    "$cenario_servidor" >"$dir/servidor.log" 2>&1 &
  local pid_servidor=$!
  # shellcheck disable=SC2064 # o pid é o de agora, de propósito
  trap "kill $pid_servidor 2>/dev/null" EXIT
  local pronto=""
  for _ in $(seq 150); do
    if grep -q "^pronto" "$dir/servidor.log" 2>/dev/null; then
      pronto=1
      break
    fi
    sleep 0.1
  done
  if [ -z "$pronto" ]; then
    kill "$pid_servidor" 2>/dev/null
    printf '%s\tfalhou\t-\t-\to servidor do teste não subiu: %s\n' "$cenario" \
      "$(tr '\n' ' ' <"$dir/servidor.log" | tail -c 200)" >"$dir/veredito"
    return
  fi

  # Invólucros: toda conexão do script vai para o servidor local.
  cat >"$dir/bin/curl" <<EOF
#!/usr/bin/env bash
exec "$curl_real" --connect-to ::127.0.0.1:$porta --insecure "\$@"
EOF
  cat >"$dir/bin/openssl" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = s_client ]; then
  args=()
  while [ \$# -gt 0 ]; do
    if [ "\$1" = -connect ]; then args+=(-connect 127.0.0.1:$porta); shift 2
    else args+=("\$1"); shift; fi
  done
  exec "$openssl_real" "\${args[@]}"
fi
exec "$openssl_real" "\$@"
EOF
  chmod +x "$dir/bin/curl" "$dir/bin/openssl"

  local inicio codigo duracao
  inicio=$(date +%s)
  (
    cd "$dir" &&
      PATH="$dir/bin:$PATH" MINUTOS=3 LIMITE_LENTO=3 ALVOS=todos ALVO_EXTRA="" \
        GITHUB_STEP_SUMMARY="$dir/resumo.md" bash -e "$script" >"$dir/saida.log" 2>&1
  )
  codigo=$?
  duracao=$(($(date +%s) - inicio))
  kill "$pid_servidor" 2>/dev/null

  local resultado=passou motivo="" alarme
  alarme=$(grep -m1 '::error' "$dir/saida.log" || true)
  case $cenario in
    hoje)
      if [ "$codigo" -ne 0 ] || [ -n "$alarme" ]; then
        resultado=falhou
        motivo="alarme falso (saída $codigo): ${alarme:-sem ::error}"
      elif ! grep -q "^app.atendoc.com.br .* 200$" "$dir/servidor.log"; then
        resultado=falhou
        motivo="a tela da produção não chegou a responder 200 ao vigia"
      fi
      ;;
    certificado)
      if [ "$codigo" -eq 0 ] || ! grep -q '::error.*certificado vence em' "$dir/saida.log"; then
        resultado=falhou
        motivo="sem alarme de certificado (saída $codigo)"
      fi
      ;;
    armazenamento-503)
      if [ "$codigo" -ne 0 ] || [ -n "$alarme" ]; then
        resultado=falhou
        motivo="alarme pelo armazenamento (saída $codigo): ${alarme:-sem ::error}"
      elif ! grep -q '::warning::.*Produção · API.*armazenamento' "$dir/saida.log"; then
        resultado=falhou
        motivo="sem aviso do armazenamento"
      elif ! grep -q "^api.atendoc.com.br /saude 503$" "$dir/servidor.log"; then
        resultado=falhou
        motivo="o vigia não chegou a ler o /saude da produção"
      else
        alarme=$(grep -m1 '::warning::.*Produção · API.*armazenamento' "$dir/saida.log")
      fi
      ;;
    armazenamento-limiar)
      if [ "$codigo" -eq 0 ] || ! grep -q '::error.*Produção · API.*armazenamento' "$dir/saida.log"; then
        resultado=falhou
        motivo="sem alarme do armazenamento (saída $codigo): ${alarme:-sem ::error}"
      elif grep -q '::error.*Produção · API fora do ar' "$dir/saida.log"; then
        resultado=falhou
        motivo="o armazenamento virou API fora do ar"
      fi
      ;;
    *)
      local alvo="Produção · app"
      case $cenario in banco-503 | saude-sem-json) alvo="Produção · API" ;; esac
      if [ "$codigo" -eq 0 ] || ! grep -q "::error.*$alvo fora do ar" "$dir/saida.log"; then
        resultado=falhou
        motivo="queda sem alarme de $alvo (saída $codigo): ${alarme:-sem ::error}"
      elif [ "$duracao" -gt "$LIMITE_ALARME" ]; then
        resultado=falhou
        motivo="alarme só depois de $duracao s"
      fi
      ;;
  esac
  [ -z "$motivo" ] && motivo=$alarme
  printf '%s\t%s\t%s\t%s s\t%s\n' "$cenario" "$resultado" "$codigo" "$duracao" "$motivo" >"$dir/veredito"
}

echo "Workflow: $workflow"
echo "Cenários: ${cenarios[*]} (em paralelo, uns 3 minutos)"
porta=${PORTA_BASE:-18443}
for cenario in "${cenarios[@]}"; do
  case $cenario in
    hoje | queda-502 | sem-resposta | redirecionamento-errado | certificado) ;;
    armazenamento-503 | armazenamento-limiar | banco-503 | saude-sem-json) ;;
    *) echo "cenário desconhecido: $cenario"; exit 2 ;;
  esac
  rodar_cenario "$cenario" "$porta" &
  porta=$((porta + 1))
done
wait

falhas=0
printf '\n%s\t%s\t%s\t%s\t%s\n' cenário resultado saída duração alarme
for cenario in "${cenarios[@]}"; do
  if [ -f "$trabalho/$cenario/veredito" ]; then
    cat "$trabalho/$cenario/veredito"
    grep -q "	falhou	" "$trabalho/$cenario/veredito" && falhas=$((falhas + 1))
  else
    printf '%s\tfalhou\t-\t-\tsem veredito\n' "$cenario"
    falhas=$((falhas + 1))
  fi
done
echo
if [ "$falhas" -gt 0 ]; then
  echo "$falhas cenário(s) falharam."
  exit 1
fi
echo "Todos os cenários passaram."
