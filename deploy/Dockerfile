# Exact version: a moving tag would change the entry point of the platform without a commit.
FROM nginx:1.30.5-alpine

# The image ships a default server on port 80; this gateway has its own
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf.d/ /etc/nginx/conf.d/
COPY nginx/snippets/ /etc/nginx/snippets/
COPY nginx/routes/ /etc/nginx/routes/
# Rendered by the image entrypoint with the variables of the environment (ALLOWED_ORIGIN)
COPY nginx/templates/ /etc/nginx/templates/
