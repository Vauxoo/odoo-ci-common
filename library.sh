#!/usr/bin/env bash

decompose_repo_url(){
    REPO="${1}"
    BIN="$( echo "${REPO}" | awk -F'+' '{print $1}' )"
    [ -z "${BIN}" ] && BIN="git"
    [ "${BIN}" != "git" ] && [ "${BIN}" != "hg"  ] && BIN="git"
    BRANCH="$( echo "${REPO}" | awk -F'@' '{print $2}' | awk -F'#' '{print $1}' )"
    [ -z "${BRANCH}" ] && [ "${BIN}" == "git" ] && BRANCH="8.0"
    [ -z "${BRANCH}" ] && [ "${BIN}" == "hg" ] && BRANCH="default"
    URL="$( echo "${REPO}" | sed "s|${BIN}+||g;s|@${BRANCH}.*||g" )"
    [ "${BIN}" == "git" ] && OPTIONS="--depth 1 -q -b ${BRANCH}"
    [ "${BIN}" == "hg" ] && OPTIONS="-q -b ${BRANCH}"
    NAME="$( python -c "
import os
try:
    from urlparse import urlparse
except ImportError:
    from urllib.parse import urlparse

print(os.path.basename(urlparse('${URL}').path))" )"
    echo "${BIN} ${URL} ${NAME} ${OPTIONS}"
}

git_clone_copy(){
    URL="${1}"
    BRANCH="${2}"
    WHAT="${3}"
    WHERE="${4}"
    TEMPDIR="$( mktemp -d )"
    echo "Cloning ${URL} ..."
    mkdir -p $( dirname "${WHERE}" )
    git clone ${URL} --depth 1 -b ${BRANCH} -q --single-branch --recursive ${TEMPDIR}
    rsync -aqz "${TEMPDIR}/${WHAT}" "${WHERE}"
    rm -rf ${TEMPDIR}
}

zip_download_copy(){
    URL="${1}"
    WHAT="${2}"
    WHERE="${3}"
    TEMPDIR="$( mktemp -d )"
    echo "Downloading ${URL} ..."
    mkdir -p $( dirname "${WHERE}" )
    wget -qO- "${URL}" | bsdtar -xf - -C "${TEMPDIR}/"
    rsync -aqz "${TEMPDIR}/${WHAT}" "${WHERE}"
    rm -rf "${TEMPDIR}"
}

git_clone_execute(){
    URL="${1}"
    BRANCH="${2}"
    SCRIPT="${3}"
    TEMPDIR="$( mktemp -d )"
    echo "Cloning ${URL} ..."
    git clone ${URL} --depth 1 -b ${BRANCH} -q --single-branch --recursive ${TEMPDIR}
    (cd ${TEMPDIR} && ./${SCRIPT})
    rm -rf ${TEMPDIR}
}

targz_download_execute(){
    URL="${1}"
    SCRIPT="${2}"
    TEMPDIR="$( mktemp -d )"
    echo "Downloading ${URL} ..."
    wget -qO- "${URL}" | tar -xz -C "${TEMPDIR}/"
    bash ${TEMPDIR}/*/${SCRIPT}
    rm -rf "${TEMPDIR}"
}


# Helper function to add a custom apt source
conf_aptsources(){
    >/etc/apt/sources.list
    for REPO in "${@}"; do
        echo "${REPO}" >> /etc/apt/sources.list
    done
}

# Helper function to add a custom apt source
add_custom_aptsource(){
    REPO="${1}"
    KEY="${2}"
    echo "${REPO}" >> /etc/apt/sources.list.d/100-vauxoo-repos.list
    wget -qO- "${KEY}" | apt-key add -
}


py_download_execute(){
    URL="${1}"
    wget -qO- "${URL}" | python3
}

createuser_custom(){
    USER="${1}"
    useradd -d "/home/${USER}" -m -s "/bin/bash" "${USER}"
    su - ${USER} -c "git config --global user.name ${USER}"
    su - ${USER} -c "git config --global user.email ${USER}@email.com"
}

psql_create_role(){
    su - postgres -c "psql -c  \"CREATE ROLE ${1} LOGIN PASSWORD '${2}' SUPERUSER INHERIT CREATEDB CREATEROLE;\""
}

service_postgres_without_sudo(){
    USER="${1}"
    VERSIONS=$(pg_lsclusters  | sed '1d' | awk '{print $1}' )
    for version in $VERSIONS; do
        pg_dropcluster --stop $version main
    done
    adduser ${USER} postgres
    chown -R ${USER}:postgres /var/run/postgresql
    for version in $VERSIONS; do
        pg_createcluster -u ${USER} -g postgres -s /var/run/postgresql -p 15432 --lc-collate=${LC_COLLATE} --start-conf auto --start $version main
        echo "include = '/etc/postgresql-common/common-vauxoo.conf'" >> /etc/postgresql/$version/main/postgresql.conf
        su - ${USER} -c "psql -p 15432 -d postgres -c  \"ALTER ROLE ${USER} WITH PASSWORD 'aeK5NWNr2';\""
        su - ${USER} -c "psql -p 15432 -d postgres -c  \"CREATE ROLE postgres LOGIN SUPERUSER INHERIT CREATEDB CREATEROLE;\""
        /etc/init.d/postgresql stop $version
        sed -i "s/port = 15432/port = 5432/g" /etc/postgresql/$version/main/postgresql.conf
    done

}

install_pyflame(){
    apt-get update
    apt-get install autoconf automake autotools-dev g++ libtool pkg-config git -y
    git clone --depth=1 --single-branch https://github.com/uber/pyflame.git /tmp/pyflame
    (cd /tmp/pyflame && \
        ./autogen.sh && \
        ./configure && \
        make && \
        make install)
    rm -rf /tmp/pyflame
    git clone --depth=1 --single-branch https://github.com/brendangregg/FlameGraph /tmp/flamegraph
    cp /tmp/flamegraph/flamegraph.pl /usr/local/bin/
}

install_tmux(){
    git clone -b 2.8 --single-branch --depth=1 https://github.com/tmux/tmux.git /tmp/tmux
    apt-get install -y libevent-dev
    (cd /tmp/tmux && \
        ./autogen.sh --silent && \
        ./configure --silent && make --silent && \
        make install
    )
    rm -rf /tmp/tmux
}

install_py37(){
    # Based on https://github.com/docker-library/python/blob/7a794688c7246e7eff898f5288716a3e7dc08484/3.7/stretch/Dockerfile
    export GPG_KEY=0D96DF4D4110E5C43FBFB17F2D347EA6AA65421D
    export PYTHON_VERSION=3.7.0
    wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" \
    && wget -O python.tar.xz.asc "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz.asc" \
    && export GNUPGHOME="$(mktemp -d)" \
    && (gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$GPG_KEY" \
        || gpg --batch --keyserver pgp.mit.edu --recv-keys --recv-keys "$GPG_KEY" \
        || gpg --batch --keyserver keyserver.pgp.com --recv-keys --recv-keys "$GPG_KEY" ) \
    && gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$GPG_KEY" \
    && gpg --batch --verify python.tar.xz.asc python.tar.xz \
    && { command -v gpgconf > /dev/null && gpgconf --kill all || :; } \
    && rm -rf "$GNUPGHOME" python.tar.xz.asc \
    && mkdir -p /usr/src/python \
    && tar -xJC /usr/src/python --strip-components=1 -f python.tar.xz \
    && rm python.tar.xz \
    \
    && (cd /usr/src/python \
    && gnuArch="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    && ./configure \
        --build="$gnuArch" \
        --enable-loadable-sqlite-extensions \
        --enable-shared \
        --with-system-expat \
        --with-system-ffi \
        --without-ensurepip \
        --silent > /dev/null 2>&1 \
    && make -j "$(nproc)" --silent > /dev/null 2>&1\
    && make install --silent > /dev/null 2>&1 \
    && ldconfig) \
    \
    && find /usr/local -depth \
        \( \
            \( -type d -a \( -name test -o -name tests \) \) \
            -o \
            \( -type f -a \( -name '*.pyc' -o -name '*.pyo' \) \) \
        \) -exec rm -rf '{}' + \
    && rm -rf /usr/src/python \
    \
    && python3.7 --version
    unset GPG_KEY PYTHON_VERSION GNUPGHOME
}


geoip_install(){
    URL="${1}"
    DIR="$( mktemp -d )"
    wget -qO- "${URL}" | tar -xz -C "${DIR}/"
    mkdir -p /usr/share/GeoIP/
    mv "$(find ${DIR} -name "GeoLite2-City.mmdb")" "/usr/share/GeoIP/GeoLite2-City.mmdb"
    rm -rf "${DIR}"
}

clean_requirements(){
    python -c "
import re
req = open('$1', 'r').read()
req = list(set(req.split('\n')))
req2 = []
regex = r'([a-z](([0-9][a-z])|([a-z]+)))(((==|>=)[0-9].+)|'')'
for i in req:
    match = re.match(regex, i, re.I)
    if match:
        req2.append(i)
open('$1', 'w').writelines('\n'.join(req2))"
}

extract_vcs(){
    python -c "
import re
x='''${1}'''
print ' '.join(re.findall(r'((?:git|hg)\+https?://[^\s]+)', x))"
}


extract_pip(){
    python -c "
import re
regex=r'(?:git|hg)\+\w+:\/{2}[\d\w-]+(\.[\d\w-]+)*(?:(?:\/[^\s/]*))*'
x='''${1}'''
print re.sub(regex, '', x)"
}


collect_pip_dependencies(){
    REPOLIST="${1}"
    DEPENDENCIES="${2}"
    REQFILE="${3}"
    TEMPDIR="$( mktemp -d )"
    TEMPFILE="$( tempfile )"
    PIP_OPTS="--upgrade"
    
    for REPO in ${REPOLIST}; do
        read BIN URL NAME OPTIONS <<< "$( decompose_repo_url "${REPO}" )"
        if [ ! -e "${TEMPDIR}/${NAME}" ]; then
            ${BIN} clone ${URL} ${OPTIONS} ${TEMPDIR}/${NAME}
        fi
    done

    for OCA in $( find ${TEMPDIR} -type f -iname "oca_dependencies.txt" ); do
        read BIN URL NAME OPTIONS <<< "$( decompose_repo_url "$( cat "${OCA}" | awk '{print $2}' )" )"
        if [ ! -e "${TEMPDIR}/${NAME}" ]; then
            ${BIN} clone ${URL} ${OPTIONS} ${TEMPDIR}/${NAME}
        fi
    done

    # Install PIP_DEPENDS_EXTRA and
    # the required requirements-parser for the next step
    python${TRAVIS_PYTHON_VERSION} -m pip install ${PIP_OPTS} ${DEPENDENCIES} future

    for REQ in $( find ${TEMPDIR} -type f -iname "requirements.txt" ); do
        python${TRAVIS_PYTHON_VERSION} /usr/share/odoo-ci-common/gen_pip_deps ${REQ} ${DEPENDENCIES_FILE}
    done
}

install_ci_environment(){
    # Init without download to add odoo remotes
    git init ${REPO_REQUIREMENTS}/odoo
    # The following section is not run on Travis because it takes too much time,
    # which sometimes results in a timeout error
    if [ ${IS_TRAVIS} != "true" ]; then
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" remote add vauxoo "${ODOO_VAUXOO_REPO}"
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" remote add vauxoo-dev "${ODOO_VAUXOO_DEV_REPO}"
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" remote add odoo "${ODOO_ODOO_REPO}"
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" remote add oca "${ODOO_OCA_REPO}"

        # Download the cached branches to avoid the download by each build
        for version in ${VERSION} 'master'; do
            git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" fetch vauxoo ${version} --depth=10
            git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" fetch odoo ${version} --depth=10
        done
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" fetch oca 11.0 --depth=10

        # Clean
        git --git-dir="${REPO_REQUIREMENTS}/odoo/.git" gc --aggressive
    fi

    # Clone tools
    git_clone_copy "${GIST_VAUXOO_REPO}" "master" "" "${REPO_REQUIREMENTS}/tools/gist-vauxoo"
    ln -s "${REPO_REQUIREMENTS}/tools" "${HOME}/tools"
    git_clone_copy "${MQT_REPO}" "master" "" "${REPO_REQUIREMENTS}/linit_hook"
    git_clone_copy "${PYLINT_REPO}" "master" "conf/pylint_vauxoo_light.cfg" "${REPO_REQUIREMENTS}/linit_hook/travis/cfg/travis_run_pylint.cfg"
    git_clone_copy "${PYLINT_REPO}" "master" "conf/pylint_vauxoo_light_pr.cfg" "${REPO_REQUIREMENTS}/linit_hook/travis/cfg/travis_run_pylint_pr.cfg"
    git_clone_copy "${PYLINT_REPO}" "master" "conf/pylint_vauxoo_light_beta.cfg" "${REPO_REQUIREMENTS}/linit_hook/travis/cfg/travis_run_pylint_beta.cfg"
    git_clone_copy "${PYLINT_REPO}" "master" "conf/pylint_vauxoo_light_vim.cfg" "${REPO_REQUIREMENTS}/linit_hook/travis/cfg/travis_run_pylint_vim.cfg"
    git_clone_copy "${PYLINT_REPO}" "master" "conf/.jslintrc" "${REPO_REQUIREMENTS}/linit_hook/travis/cfg/.jslintrc"
    ln -sf ${REPO_REQUIREMENTS}/linit_hook/git/* /usr/share/git-core/templates/hooks/

    # Create virtual environments for all installed Python versions
    echo "Creating a virtualenv using python${TRAVIS_PYTHON_VERSION}"
    python${TRAVIS_PYTHON_VERSION} -m virtualenv --system-site-packages ${REPO_REQUIREMENTS}/virtualenv/python${TRAVIS_PYTHON_VERSION}
    # Install coverage in the virtual environment
    # Please don't remove it because emit errors from other environments
    source ${REPO_REQUIREMENTS}/virtualenv/python${TRAVIS_PYTHON_VERSION}/bin/activate
    pip install --force-reinstall --upgrade coverage --src .

    # Execute travis_install_nightly
    echo "Installing the linit pip requirements using python${TRAVIS_PYTHON_VERSION}"
    LINT_CHECK=1 TESTS=0 ${REPO_REQUIREMENTS}/linit_hook/travis/travis_install_nightly
    pip install --no-binary pycparser -r ${REPO_REQUIREMENTS}/linit_hook/requirements.txt
    deactivate

}


