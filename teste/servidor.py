"""Servidor HTTPS local que imita as respostas do Atendoc para os testes do vigia.

Responde pelo cabeçalho Host, como os endereços de verdade. O cenário muda só
a tela da produção (app.atendoc.com.br); os outros alvos respondem como hoje.

Respostas de hoje (16/11/2026, conferidas com curl na produção):
  https://app.atendoc.com.br/        -> 307, Location: /entrar
  https://app.atendoc.com.br/entrar  -> 200, text/html

Uso: python servidor.py <porta> <certificado.pem> <chave.pem> <cenário>
"""

import http.server
import ssl
import sys
import time

APP_PRODUCAO = "app.atendoc.com.br"
TELAS = {APP_PRODUCAO, "app.staging.atendoc.com.br"}
APIS = {"api.atendoc.com.br", "api.staging.atendoc.com.br"}
TELEPORT = "acesso.atendoc.com.br"

CENARIOS = {"hoje", "queda-502", "sem-resposta", "redirecionamento-errado"}


def resposta_de_hoje(host, caminho):
    """(código, cabeçalhos) que cada alvo devolve hoje."""
    if host in TELAS:
        if caminho == "/":
            return 307, {"Location": "/entrar"}
        if caminho == "/entrar":
            return 200, {}
        return 404, {}
    if host in APIS and caminho in ("/saude", "/up"):
        return 200, {}
    if host == TELEPORT and caminho == "/web/login":
        return 200, {}
    return 404, {}


def resposta(cenario, host, caminho):
    if host == APP_PRODUCAO:
        if cenario == "queda-502":
            return 502, {}
        if cenario == "sem-resposta":
            # O vigia desiste em 15 s (curl --max-time 15).
            time.sleep(20)
            return 502, {}
        if cenario == "redirecionamento-errado" and caminho in ("/", "/entrar"):
            return 302, {"Location": "https://manutencao.exemplo.invalid/"}
    return resposta_de_hoje(host, caminho)


class Manipulador(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cenario = "hoje"

    def do_GET(self):
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        caminho = self.path.split("?")[0]
        codigo, cabecalhos = resposta(self.cenario, host, caminho)
        print(f"{host} {caminho} {codigo}", flush=True)
        corpo = b"<!doctype html><title>Atendoc</title>" if codigo == 200 else b""
        try:
            self.send_response(codigo)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(corpo)))
            for nome, valor in cabecalhos.items():
                self.send_header(nome, valor)
            self.end_headers()
            self.wfile.write(corpo)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def main():
    porta, certificado, chave, cenario = sys.argv[1:5]
    if cenario not in CENARIOS:
        sys.exit(f"cenário desconhecido: {cenario}")
    Manipulador.cenario = cenario
    contexto = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    contexto.load_cert_chain(certificado, chave)
    servidor = http.server.ThreadingHTTPServer(("127.0.0.1", int(porta)), Manipulador)
    servidor.daemon_threads = True
    servidor.socket = contexto.wrap_socket(servidor.socket, server_side=True)
    print(f"pronto {porta}", flush=True)
    servidor.serve_forever()


if __name__ == "__main__":
    main()
