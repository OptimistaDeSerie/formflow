# Frontend image: nginx serves the web page and forwards /api/ calls to the backend.
# No secrets in this file.
FROM nginx:1.27-alpine

# The image tag is passed in at build time and written to a small file the page can read.
ARG APP_VERSION=unknown

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt

EXPOSE 80
