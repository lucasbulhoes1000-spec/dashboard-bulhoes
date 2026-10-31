#!/bin/sh
# Atualiza a versão do Lume antes de publicar (o app no celular recarrega quando ela muda)
cd "$(dirname "$0")/.." && sed -i "s/<meta name=\"lume-versao\" content=\"[^\"]*\">/<meta name=\"lume-versao\" content=\"$(TZ=America/Sao_Paulo date +%Y%m%d-%H%M%S)\">/" index.html && grep -o 'lume-versao" content="[^"]*' index.html
