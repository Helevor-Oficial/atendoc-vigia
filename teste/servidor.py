"""Servidor HTTPS local que imita as respostas do Atendoc para os testes do vigia.

Responde pelo cabeçalho Host, como os endereços de verdade. O cenário muda só
a tela da produção (app.atendoc.com.br) ou o /saude da API da produção
(api.atendoc.com.br); os outros alvos respondem como hoje.

Respostas de hoje (16/11/2026, conferidas com curl na produção):
  https://app.atendoc.com.br/        -> 307, Location: /entrar
  https://app.atendoc.com.br/entrar  -> 200, text/html
  https://api.atendoc.com.br/saude   -> 200, {"situacao":"ok","banco":"responde",
                                        "armazenamento":"responde","fila":"responde",...}
O /saude responde 503 com a parte que não respondeu marcada "sem resposta"
(src/saude/saude.ts do atendoc-back).

Uso: python servidor.py <porta> <certificado.pem> <chave.pem> <cenário>
"""

import http.server
import json
import ssl
import sys
import time

APP_PRODUCAO = "app.atendoc.com.br"
TELAS = {APP_PRODUCAO, "app.staging.atendoc.com.br"}
API_PRODUCAO = "api.atendoc.com.br"
APIS = {API_PRODUCAO, "api.staging.atendoc.com.br"}
TELEPORT = "acesso.atendoc.com.br"

CENARIOS = {
    "hoje", "queda-502", "sem-resposta", "redirecionamento-errado",
    "armazenamento-503", "banco-503", "saude-sem-json",
}
HTML = "text/html; charset=utf-8"


def saude(banco="responde", armazenamento="responde", fila="responde"):
    """(código, cabeçalhos, corpo) do /saude, como o SaudeControlador do back."""
    ok = banco == armazenamento == fila == "responde"
    corpo = json.dumps({
        "situacao": "ok" if ok else "falha", "banco": banco, "armazenamento": armazenamento,
        "fila": fila, "ambiente": "producao", "versao": "teste",
    }, ensure_ascii=False, separators=(",", ":"))
    return (200 if ok else 503), {"Content-Type": "application/json; charset=utf-8"}, corpo.encode("utf-8")


def resposta_de_hoje(host, caminho):
    """(código, cabeçalhos, corpo) que cada alvo devolve hoje."""
    if host in TELAS:
        if caminho == "/":
            return 307, {"Location": "/entrar"}, b""
        if caminho == "/entrar":
            return 200, {}, b"<!doctype html><title>Atendoc</title>"
        return 404, {}, b""
    if host in APIS and caminho == "/saude":
        return saude()
    if host in APIS and caminho == "/up":
        return 200, {}, b"<!doctype html><title>up</title>"
    if host == TELEPORT and caminho == "/web/login":
        return 200, {}, b"<!doctype html><title>Teleport</title>"
    return 404, {}, b""


def resposta(cenario, host, caminho):
    if host == APP_PRODUCAO:
        if cenario == "queda-502":
            return 502, {}, b""
        if cenario == "sem-resposta":
            # O vigia desiste em 15 s (curl --max-time 15).
            time.sleep(20)
            return 502, {}, b""
        if cenario == "redirecionamento-errado" and caminho in ("/", "/entrar"):
            return 302, {"Location": "https://manutencao.exemplo.invalid/"}, b""
    if host == API_PRODUCAO and caminho == "/saude":
        if cenario == "armazenamento-503":
            # O armazenamento da Contabo sem resposta, o resto no ar (MSF-510).
            return saude(armazenamento="sem resposta")
        if cenario == "banco-503":
            # Banco fora; o armazenamento também, para provar que o banco manda.
            return saude(banco="sem resposta", armazenamento="sem resposta")
        if cenario == "saude-sem-json":
            # O proxy sem a API atrás: 503 sem o JSON do /saude.
            return 503, {}, b""
    return resposta_de_hoje(host, caminho)


class Manipulador(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cenario = "hoje"

    def do_GET(self):
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        caminho = self.path.split("?")[0]
        codigo, cabecalhos, corpo = resposta(self.cenario, host, caminho)
        print(f"{host} {caminho} {codigo}", flush=True)
        cabecalhos = {"Content-Type": HTML, **cabecalhos}
        try:
            self.send_response(codigo)
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
