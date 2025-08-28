#!/usr/bin/env bash
set -euo pipefail

### ============================
### Configurações principais
### ============================

# Caminhos
ROOT="${PWD}"
BUILD_DIR="$ROOT/build"
PKG_DIR="$ROOT/pkg"
LOG_DIR="$ROOT/logs"
REPO_DIR="$ROOT/repo"
SRC_DIR="$ROOT/sources"

# Programas
CURL="curl -L -o"
GIT="git clone"
TAR="tar"
UNZIP="unzip -q"
SEVENZ="7z"
PATCH="patch -p1"
STRIP_CMD="strip --strip-unneeded"
FAKEROOT="fakeroot"

# Opções padrão
NPROC="$(nproc || echo 1)"
STRIP_DEFAULT="yes"
COLOR="yes"

### ============================
### Cores e mensagens
### ============================
if [[ "$COLOR" == "yes" ]]; then
    C_RESET="\033[0m"; C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

msg() { echo -e "${C_BLUE}==>${C_RESET} $*"; }
success() { echo -e "${C_GREEN}✔${C_RESET} $*"; }
error() { echo -e "${C_RED}✘${C_RESET} $*" >&2; exit 1; }

spinner() {
    local pid=$!
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${C_YELLOW}[${spin:$i:1}]${C_RESET} "
        sleep .1
    done
    echo -ne "\r"
}

### ============================
### Funções auxiliares
### ============================

# Carregar receita (key=[value])
load_recipe() {
    local recipe="$1"
    source <(sed -E 's/^\s*([a-zA-Z0-9_]+)=\[(.*)\]/\1="\2"/' "$recipe")
}

# Download (curl ou git)
fetch() {
    local url="$1" dest="$2"
    if [[ "$url" =~ ^git ]]; then
        msg "Clonando repositório: $url"
        $GIT "$url" "$dest"
    else
        msg "Baixando: $url"
        $CURL "$dest" "$url" & spinner
    fi
}

# Checar md5
check_md5() {
    local file="$1" expect="$2"
    echo "$expect  $file" | md5sum -c -
}

# Extrair
extract() {
    local file="$1" dest="$2"
    mkdir -p "$dest"
    case "$file" in
        *.tar.gz|*.tgz) $TAR -xzf "$file" -C "$dest" ;;
        *.tar.bz2) $TAR -xjf "$file" -C "$dest" ;;
        *.tar.xz) $TAR -xJf "$file" -C "$dest" ;;
        *.tar) $TAR -xf "$file" -C "$dest" ;;
        *.zip) $UNZIP "$file" -d "$dest" ;;
        *.7z) $SEVENZ x "$file" -o"$dest" ;;
        *) error "Formato não suportado: $file" ;;
    esac
}

# Registrar instalação
register_pkg() {
    echo "$pkgname $pkgver $pkgdir" >> "$LOG_DIR/installed.log"
}

# Remover registro
unregister_pkg() {
    grep -v "^$1 " "$LOG_DIR/installed.log" > "$LOG_DIR/tmp" || true
    mv "$LOG_DIR/tmp" "$LOG_DIR/installed.log"
}

### ============================
### Build e Install
### ============================

# Só build (sem instalar)
build_pkg() {
    local recipe="$1"
    load_recipe "$recipe"

    local work="$BUILD_DIR/$pkgname-$pkgver"
    local tarball="$SRC_DIR/$pkgname-$pkgver.tar"

    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$PKG_DIR" "$SRC_DIR"

    # Download fonte
    if [[ ! -f "$tarball" ]]; then
        fetch "$pkgurl" "$tarball"
        check_md5 "$tarball" "$md5sum"
    fi

    # Extrair
    rm -rf "$work"
    extract "$tarball" "$BUILD_DIR"

    # Patch opcional
    if [[ -n "${patchurl:-}" ]]; then
        local patchfile="$SRC_DIR/${pkgname}-${pkgver}.patch"
        fetch "$patchurl" "$patchfile"
        check_md5 "$patchfile" "$patchmd5"
        (cd "$work" && $PATCH < "$patchfile")
    fi

    # Hooks até build
    [[ -n "${preconfig:-}" ]] && (cd "$work" && eval "$preconfig")
    [[ -n "${prepare:-}" ]]   && (cd "$work" && eval "$prepare")
    [[ -n "${build:-}" ]]     && (cd "$work" && eval "$build")

    success "$pkgname $pkgver compilado (não instalado)"
}

# Instalar (a partir do build existente)
install_pkg() {
    local recipe="$1"
    load_recipe "$recipe"

    local work="$BUILD_DIR/$pkgname-$pkgver"
    DESTDIR="$PKG_DIR/$pkgdir"

    if [[ ! -d "$work" ]]; then
        error "Pacote $pkgname-$pkgver não foi compilado ainda. Rode './lfs.sh build <recipe>' antes."
    fi

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"

    [[ -n "${install:-}" ]] && $FAKEROOT bash -c "(cd \"$work\" && eval \"$install\")"

    # Strip opcional
    if [[ "${STRIP:-$STRIP_DEFAULT}" == "yes" ]]; then
        find "$DESTDIR" -type f -exec file {} \; | grep ELF | cut -d: -f1 | \
            xargs -r $STRIP_CMD || true
    fi

    # Empacotamento só se não for toolchain
    if [[ "${TOOLCHAIN:-no}" == "no" ]]; then
        PKGFILE="$PKG_DIR/${pkgname}-${pkgver}.tar.xz"
        tar -C "$DESTDIR" -cJf "$PKGFILE" .
        success "Pacote criado: $PKGFILE"
    fi

    register_pkg
    success "$pkgname $pkgver instalado em $DESTDIR"
}

### ============================
### Extras
### ============================

clean() { rm -rf "$BUILD_DIR"/*; success "Build limpo"; }
remove_pkg() { unregister_pkg "$1"; rm -rf "$PKG_DIR/$1"* && success "$1 removido"; }
list_pkgs() { cat "$LOG_DIR/installed.log" || echo "Nenhum instalado"; }
info_pkg() { grep "^$1 " "$LOG_DIR/installed.log" || echo "$1 não instalado"; }

new_recipe() {
    local category="$1"
    mkdir -p "$REPO_DIR/$category"
    cat > "$REPO_DIR/$category/model.recipe" <<EOF
pkgdir=[example-1.0-1]
pkgname=[example]
pkgver=[1.0]
pkgurl=[http://example.org/example-1.0.tar.gz]
md5sum=[xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx]

preconfig=[mkdir -p build]
prepare=[cd build && ../configure --prefix=/usr]
build=[cd build && make -j\$(nproc)]
install=[cd build && make DESTDIR=\$DESTDIR install]
EOF
    success "Modelo criado em $REPO_DIR/$category/model.recipe"
}

### ============================
### CLI
### ============================

case "${1:-}" in
    build) build_pkg "$2" ;;
    install) install_pkg "$2" ;;
    clean) clean ;;
    remove) remove_pkg "$2" ;;
    list) list_pkgs ;;
    info) info_pkg "$2" ;;
    new) new_recipe "$2" ;;
    *)
        echo "Uso: $0 {build <recipe>|install <recipe>|clean|remove <pkg>|list|info <pkg>|new <dir>}"
        ;;
esac
