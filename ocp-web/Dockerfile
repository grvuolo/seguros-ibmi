FROM registry.access.redhat.com/ubi9/nodejs-20

WORKDIR /opt/app-root/src
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.js ./
COPY public ./public

EXPOSE 8080
CMD ["node", "server.js"]
