# Vigia do Atendoc

Verificação de disponibilidade do Atendoc feita de fora da Contabo pelo GitHub Actions (história E00-H27). Testa a aplicação e a API de produção e de staging e a página de login do Teleport uma vez por minuto, e falha quando um alvo passa 3 minutos seguidos sem responder, quando responde acima de 3 s por 5 minutos seguidos, ou quando um certificado está a menos de 14 dias de vencer.

A API é testada pelo `/saude`, que responde 503 quando o banco, a fila ou o armazenamento de arquivos não respondem e diz qual no JSON. 503 só com o armazenamento sem resposta (o armazenamento da Contabo fica assim por minutos seguidos de madrugada) não conta como fora do ar: vira aviso no resumo e tem alarme próprio com 15 minutos seguidos. 503 com o banco ou a fila sem resposta, ou sem o JSON, segue a regra dos 3 minutos.

Quando o workflow falha, o GitHub manda e-mail para quem escreveu o agendamento. É a segunda camada do monitoramento: a primeira é o Uptime Kuma, que roda na própria Contabo e não avisa se ela cair inteira.

## Por que um laço de até 340 minutos

O GitHub trata o agendamento como melhor esforço. Com o cron a cada 5 minutos, em 14 e 15/10/2026 os runs saíram a cada 3 a 5 horas. Por isso cada run agendado fica testando por até 340 minutos (o limite de um job é 360), e o disparo seguinte do cron espera na fila e começa quando ele termina. Um alerta encerra o run na hora, para o e-mail sair.

## Custo

O repositório é público só para não gastar os minutos de Actions da organização: em repositório público os minutos do runner padrão são gratuitos. O laço ocupa um dos 20 jobs simultâneos do plano Free enquanto roda. O repositório contém apenas o workflow e endereços que já são públicos pelo DNS: nenhum segredo, nenhuma credencial. O resto da infraestrutura fica no `atendoc-gitops`, privado, com a documentação em `docs/monitoramento.md`.

## Provar um alerta no staging

Actions > vigia > Run workflow, com `alvos` = `staging`:

- lentidão: `limite_lento` = `0.05`. O run falha ao fim do quinto minuto.
- queda: `alvo_extra` = um endereço do staging que responde 404 (por exemplo `https://api.staging.atendoc.com.br/nao-existe`). O run falha no terceiro minuto.

O e-mail da falha de um run manual vai para quem o disparou.

## Testar sem sair para a internet

`bash teste/rodar.sh` roda o script do workflow contra um servidor HTTPS local que imita as respostas do Atendoc (`teste/servidor.py`, com Python 3), sem pedido para a produção nem para o staging. Leva uns 3 minutos e cobre nove cenários: as respostas de hoje (sem alarme), queda da tela com 502, tela sem resposta, redirecionamento para outro lugar, certificado perto de vencer, `/saude` em 503 só pelo armazenamento (aviso, sem alarme), o mesmo com o limiar do armazenamento baixado no teste (alarme próprio), `/saude` em 503 com o banco fora e `/saude` em 503 sem JSON (alarme da API em até 3 minutos). `PORTA_BASE` troca as portas locais. `bash teste/rodar.sh -w <arquivo>` testa outro workflow com o mesmo formato, como o `vigia.yml` manual do `atendoc-gitops`.

A tela é testada pela página de entrada, `/entrar`, e só resposta 2xx conta como no ar. A raiz responde 307 para `/entrar` desde 22/10/2026, e o vigia testava a raiz: de 22/10 a 16/11, toda rodada terminou com alarme falso no terceiro minuto (MSF-615).
