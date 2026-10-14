# Vigia do Atendoc

Verificação de disponibilidade do Atendoc feita de fora da Contabo, a cada 5 minutos, pelo GitHub Actions (história E00-H27). Testa a aplicação e a API de produção e de staging e a página de login do Teleport, com três tentativas por alvo, e falha também quando um certificado está a menos de 14 dias de vencer.

Quando o workflow falha, o GitHub manda e-mail para quem escreveu o agendamento. É a segunda camada do monitoramento: a primeira é o Uptime Kuma, que roda na própria Contabo e não avisa se ela cair inteira.

O repositório é público só para não gastar os minutos de Actions da organização. Ele contém apenas este workflow e endereços que já são públicos pelo DNS: nenhum segredo, nenhuma credencial. O resto da infraestrutura fica no `atendoc-gitops`, privado, com a documentação em `docs/monitoramento.md`.
