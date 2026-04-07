const fdk = require("@fnproject/fdk");

fdk.handle(async (input, ctx) => {
  const headers = ctx.headers || {};

  return {
    ok: true,
    echo: input,
    method: headers["fn-http-method"] || headers["Fn-Http-Method"] || null,
    requestUrl: headers["fn-http-request-url"] || headers["Fn-Http-Request-Url"] || null,
    headers
  };
});

