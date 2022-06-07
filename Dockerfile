FROM ubuntu:20.04 as build-stage

ARG DEBIAN_FRONTEND=noninteractive

ENV NODE_OPTIONS=--openssl-legacy-provider
ENV NODE_VERSION=17.x
ENV ZEROTIER_ONE_VERSION=1.8.9
ENV LIBPQXX_VERSION=7.6.1
#https://api.github.com/repos/dec0dOS/zero-ui/tags name
ENV ZERO_UI_VERSION=v1.3.0
#https://api.github.com/repos/just-containers/s6-overlay/releases/latest tag_name
ENV S6_OVERLAY_VERSION=v3.1.0.1

ENV TZ=Asia/Shanghai

ENV PATCH_ALLOW=0

#COPY ./sources.list /etc/apt/sources.list
    
RUN apt update && \
    apt install -y curl gnupg2

RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
    apt install -y nodejs yarn python3 wget git jq build-essential tar diffutils patch cargo openssl libssl-dev libpq-dev pkg-config

WORKDIR /src

# Prepaire Environment
COPY ./patch /src/patch
COPY ./config /src/config

# Downloading and build latest libpqxx
RUN curl https://codeload.github.com/jtv/libpqxx/tar.gz/refs/tags/${LIBPQXX_VERSION} --output /tmp/libpqxx.tar.gz && \
    mkdir -p /src && \
    cd /src && \
    tar -xvf /tmp/libpqxx.tar.gz && \
    mv /src/libpqxx-* /src/libpqxx && \
    rm -rf /tmp/libpqxx.tar.gz && \
    cd /src/libpqxx && \
    /src/libpqxx/configure --disable-documentation --with-pic && \
    make && \
    make install

# Downloading and build latest version ZeroTierOne
RUN curl https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/refs/tags/${ZEROTIER_ONE_VERSION} --output /tmp/ZeroTierOne.tar.gz && \    
    mkdir -p /src && \
    cd /src && \
    tar -xvf /tmp/ZeroTierOne.tar.gz && \
    mv /src/ZeroTierOne-${ZEROTIER_ONE_VERSION} /src/ZeroTierOne && \
    sed -i 's#<libpq-fe.h>#"/usr/include/postgresql/libpq-fe.h"#' /src/ZeroTierOne/controller/PostgreSQL.cpp && \
    rm -rf /tmp/ZeroTierOne.tar.gz

RUN python3 /src/patch/patch.py

RUN cd /src/ZeroTierOne && \
    make central-controller CPPFLAGS+=-w && \
    cd /src/ZeroTierOne/attic/world && \
    bash build.sh

# Downloading and build latest tagged zero-ui
RUN curl https://codeload.github.com/dec0dOS/zero-ui/tar.gz/refs/tags/${ZERO_UI_VERSION} --output /tmp/zero-ui.tar.gz && \
    mkdir -p /src/ && \
    cd /src && \
    tar -xvf /tmp/zero-ui.tar.gz && \
    mv /src/zero-ui-* /src/zero-ui && \
    rm -rf /tmp/zero-ui.tar.gz && \
    cd /src/zero-ui && \
    yarn install && \
    yarn installDeps && \
    yarn build

FROM ubuntu:20.04

ENV NODE_OPTIONS=--openssl-legacy-provider
ENV NODE_VERSION=17.x
ENV S6_OVERLAY_VERSION=v3.1.0.1

WORKDIR /app/ZeroTierOne

# libpqxx
COPY --from=build-stage /usr/local/lib/libpqxx.la /usr/local/lib/libpqxx.la
COPY --from=build-stage /usr/local/lib/libpqxx.a /usr/local/lib/libpqxx.a

# ZeroTierOne
COPY --from=build-stage /src/ZeroTierOne/zerotier-one /app/ZeroTierOne/zerotier-one
RUN cd /app/ZeroTierOne && \
    ln -s zerotier-one zerotier-cli && \
    ln -s zerotier-one zerotier-idtool

# mkworld @ ZeroTierOne
COPY --from=build-stage /src/ZeroTierOne/attic/world/mkworld /app/ZeroTierOne/mkworld
COPY --from=build-stage /src/ZeroTierOne/attic/world/world.bin /app/config/world.bin
COPY --from=build-stage /src/config/world.c /app/config/world.c

# Envirment
#COPY ./sources.list /etc/apt/sources.list
    
RUN apt update && \
    apt install -y curl gnupg2 

RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION} | bash - && \
    apt install -y nodejs yarn wget git bash jq tar build-essential openssl libpq-dev xz-utils && \
    mkdir -p /var/lib/zerotier-one/ && \
    ln -s /app/config/authtoken.secret /var/lib/zerotier-one/authtoken.secret

# Installing s6-overlay
RUN cd /tmp && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz  --output s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    curl --silent --location https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz --output s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -xvf /tmp/s6-overlay-noarch-${S6_OVERLAY_VERSION}.tar.xz && \
    tar -C / -xvf /tmp/s6-overlay-x86_64-${S6_OVERLAY_VERSION}.tar.xz && \
    rm -f /tmp/*.xz

# Frontend @ zero-ui
COPY --from=build-stage /src/zero-ui/frontend/build /app/frontend/build/

# Backend @ zero-ui
WORKDIR /app/backend
COPY --from=build-stage /src/zero-ui/backend/package*.json /app/backend
RUN yarn install && \
    ln -s /app/config/world.bin /app/frontend/build/static/planet
COPY --from=build-stage /src/zero-ui/backend /app/backend

# s6-overlay
COPY ./s6-files/etc /etc/
RUN chmod +x /etc/services.d/*/run

# schema
COPY ./schema /app/schema/

EXPOSE 3000 4000 9993 9993/UDP
ENV S6_KEEP_ENV=1

ENTRYPOINT ["/init"]
CMD []
