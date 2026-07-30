# 基础镜像故意锁死到具体小版本（而不是用 node:24-alpine 这种浮动 tag），
# 这样每次 build 用的 Node 版本是确定的、可复现的，升级 Node 变成一个显式的
# "改这三行 + 提交"的动作，留痕、可回滚，不会在某次不知情的重新构建里悄悄换掉。
# 升级时去 https://nodejs.org/en/blog/vulnerability 看有没有新的安全版本，
# 跟上面这些行一起改。
#
# 注：nodejs.org 发版和 Docker Hub 官方镜像同步之间通常有几小时到一两天的窗口。
# 2026-07-29 官方发布的 24.18.1（修 HTTP/2 内存问题 + Permission Model 绕过等
# HIGH 级漏洞）目前 Docker Hub 还没有对应的 -alpine 镜像，所以这里暂时锁在
# 24.18.0。等 https://hub.docker.com/_/node/tags?name=24.18.1-alpine 有了之后
# 记得把下面三行改成 24.18.1-alpine 再 build 一次。
# ---- 依赖安装 ----
FROM node:24.18.0-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci

# ---- 构建 ----
FROM node:24.18.0-alpine AS builder
RUN apk add --no-cache openssl
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# next.config.js 的图片域名白名单在这一步就会写死进构建产物，
# 必须在这里就能拿到真实值，光靠运行时的 .env 是不够的（那是启动容器时才生效）
ARG S3_PUBLIC_HOSTNAME
ENV S3_PUBLIC_HOSTNAME=$S3_PUBLIC_HOSTNAME

# 根布局（app/layout.tsx）在设置了站点 Logo 后会调用 lib/r2.ts 的 publicUrl()
# 拼 Logo 图片地址，这个函数直接读 process.env.S3_PUBLIC_URL，构建期不传的话
# 拿到的是 undefined，prerender 时 undefined.replace(...) 直接把构建炸掉
ARG S3_PUBLIC_URL
ENV S3_PUBLIC_URL=$S3_PUBLIC_URL

# next build 阶段会尝试预渲染静态/ISR页面（比如 /tags），根布局又会查
# siteSetting/navLink，所以构建时也得能连上库，跟运行时用同一个 DATABASE_URL
ARG DATABASE_URL
ENV DATABASE_URL=$DATABASE_URL

# NEXT_PUBLIC_ 开头的变量会被 next build 直接写死进前端 JS 包里，不是运行时读取的——
# 光靠容器启动时 env_file 挂进去的 .env 是不够的，那时候前端代码早就构建完了。
# 没传的话 app/components/TurnstileWidget.tsx 里 siteKey 恒为 undefined，
# 组件直接 return null 不渲染，用户永远拿不到 token，注册接口的人机验证必然失败。
ARG NEXT_PUBLIC_TURNSTILE_SITE_KEY
ENV NEXT_PUBLIC_TURNSTILE_SITE_KEY=$NEXT_PUBLIC_TURNSTILE_SITE_KEY

RUN npx prisma generate
RUN npm run build

# 把 create-admin 脚本打包成一个独立的 .cjs 文件。
# 这样运行时容器不需要再装 tsx/esbuild，也不用操心 lib/ 目录有没有一起拷进去——
# bcryptjs 和 lib/password.ts 都被打包进这一个文件里了，只有 @prisma/client 保持外部引用
# （运行时从 node_modules 正常加载，不能打包进去，因为它内部关联着生成好的查询引擎二进制文件）。
RUN npx esbuild prisma/create-admin.ts --bundle --platform=node --format=cjs \
      --outfile=prisma/create-admin.cjs --external:@prisma/client

# ---- 运行 ----
FROM node:24.18.0-alpine AS runner
RUN apk add --no-cache openssl
WORKDIR /app
ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs \
  && adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma ./node_modules/@prisma

COPY --from=builder /app/node_modules/prisma ./node_modules/prisma
COPY --from=builder /app/node_modules/.bin ./node_modules/.bin
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh

USER nextjs
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node", "server.js"]
