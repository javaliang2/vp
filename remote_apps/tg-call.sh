#!/bin/bash
# ╔══════════════════════════════════════════════════════╗
# ║     Telegram 客服中转机器人 v2  — 一键安装脚本       ║
# ║     支持: Ubuntu / Debian / CentOS / RHEL / Fedora   ║
# ╚══════════════════════════════════════════════════════╝

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/tg-relay-bot"
SERVICE_NAME="tg-relay-bot"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

banner() {
cat << 'EOF'

  ████████╗ ██████╗     ██████╗  ██████╗ ████████╗
     ██╔══╝██╔════╝     ██╔══██╗██╔═══██╗╚══██╔══╝
     ██║   ██║  ███╗    ██████╔╝██║   ██║   ██║
     ██║   ██║   ██║    ██╔══██╗██║   ██║   ██║
     ██║   ╚██████╔╝    ██████╔╝╚██████╔╝   ██║
     ╚═╝    ╚═════╝     ╚═════╝  ╚═════╝    ╚═╝

      Telegram 客服中转机器人 v2 — 一键安装程序
      功能：消息中转 · 全媒体 · 屏蔽拉黑 · 会话管理
EOF
echo ""
}

check_root() {
    [[ $EUID -eq 0 ]] || error "请用 root 权限运行: sudo bash install.sh"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release; OS=$ID; OS_VER=${VERSION_ID:-""}
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        error "无法识别操作系统，请手动安装。"
    fi
    info "操作系统: ${OS} ${OS_VER}"
}

install_system_deps() {
    step "安装系统依赖"
    case $OS in
        ubuntu|debian)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y python3 python3-pip python3-venv curl >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip curl >/dev/null 2>&1
            else
                yum install -y python3 python3-pip curl >/dev/null 2>&1
            fi ;;
        fedora)
            dnf install -y python3 python3-pip curl >/dev/null 2>&1 ;;
        *) warn "未知系统，跳过依赖安装，如报错请手动安装 python3 python3-pip" ;;
    esac
    success "系统依赖完成"
}

check_python() {
    if command -v python3 &>/dev/null && python3 -c "import sys; exit(0 if sys.version_info>=(3,8) else 1)" 2>/dev/null; then
        PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        success "Python ${PY_VER} ✓"; PYTHON_CMD="python3"; return
    fi
    warn "未找到 Python 3.8+，尝试自动安装..."
    case $OS in
        ubuntu|debian) apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1 ;;
        *) dnf install -y python3 python3-pip >/dev/null 2>&1 || yum install -y python3 python3-pip >/dev/null 2>&1 ;;
    esac
    PYTHON_CMD="python3"; success "Python 安装完成"
}

# ─────────────────────────── 交互配置 ───────────────────────────

collect_config() {
    step "配置机器人参数"

    echo ""
    echo -e "${BOLD}① Bot Token${NC}（去 @BotFather → /newbot 创建）"
    echo ""
    while true; do
        read -rp "  Token: " BOT_TOKEN
        BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d '[:space:]')
        [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{35,}$ ]] && { success "Token ✓"; break; }
        warn "格式不正确，示例: 123456789:ABCdef..."
    done

    echo ""
    echo -e "${BOLD}② 绑定主人的 Telegram 用户 ID${NC}"
    echo -e "   所有用户消息都会转发给这个账号"
    echo -e "   查询方法：给 ${CYAN}@userinfobot${NC} 发任意消息"
    echo ""
    while true; do
        read -rp "  主人 ID: " OWNER_ID
        OWNER_ID=$(echo "$OWNER_ID" | tr -d '[:space:]')
        [[ "$OWNER_ID" =~ ^[0-9]+$ ]] && { success "主人 ID: ${OWNER_ID} ✓"; break; }
        warn "ID 必须是纯数字"
    done

    echo ""
    echo -e "${BOLD}③ 匿名模式${NC}"
    echo -e "   ${GREEN}y${NC} = 匿名  主人只看到匿名编号，不显示真实用户名"
    echo -e "   ${YELLOW}n${NC} = 实名  主人能看到来信者名字和用户名（推荐）"
    echo ""
    read -rp "  启用匿名? [y/N]: " ANON_CHOICE
    if [[ "$ANON_CHOICE" =~ ^[Yy]$ ]]; then
        ANONYMOUS_MODE="True"; info "匿名模式 ✓"
    else
        ANONYMOUS_MODE="False"; info "实名模式 ✓"
    fi
}

# ─────────────────────────── 写入文件 ───────────────────────────

write_files() {
    step "写入程序文件"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # ── config.py ──
    cat > config.py << PYEOF
BOT_TOKEN      = "${BOT_TOKEN}"
OWNER_ID       = ${OWNER_ID}
ANONYMOUS_MODE = ${ANONYMOUS_MODE}
PYEOF

    # ── requirements.txt ──
    cat > requirements.txt << 'REQEOF'
python-telegram-bot==20.7
REQEOF

    # ── bot.py ──
    cat > bot.py << 'BOTEOF'
"""
Telegram 客服中转机器人 v2
══════════════════════════════════════════════════════
功能：
  • 任何用户发消息 → 自动转发给主人（卡片式布局）
  • 主人回复转发消息 → 自动转回给原用户
  • 全媒体支持：文字/图片/视频/语音/音频/文件/贴纸/
                视频留言/位置/联系人
  • 屏蔽拉黑：主人可拉黑用户，用户收到提示
  • 会话管理：/end /endall /sessions /r
  • 操作按钮：每条消息附快捷按钮（切换回复/拉黑）
══════════════════════════════════════════════════════
"""

import logging
import sqlite3
import hashlib
from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup, constants
)
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    CallbackQueryHandler, ContextTypes, filters,
)
from config import BOT_TOKEN, OWNER_ID, ANONYMOUS_MODE

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ══════════════════════════════════════════════════════
#  数据库
# ══════════════════════════════════════════════════════

DB_PATH = "chat.db"

def get_db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    with get_db() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS sessions (
            user_id     INTEGER PRIMARY KEY,
            username    TEXT,
            first_name  TEXT,
            status      TEXT    DEFAULT 'active',
            started_at  TEXT    DEFAULT (datetime('now','localtime')),
            last_msg_at TEXT    DEFAULT (datetime('now','localtime')),
            ended_at    TEXT,
            msg_count   INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS reply_target (
            id      INTEGER PRIMARY KEY CHECK (id=1),
            user_id INTEGER
        );

        CREATE TABLE IF NOT EXISTS msg_map (
            owner_msg_id INTEGER PRIMARY KEY,
            user_id      INTEGER NOT NULL,
            created_at   TEXT DEFAULT (datetime('now','localtime'))
        );

        CREATE TABLE IF NOT EXISTS blocklist (
            user_id    INTEGER PRIMARY KEY,
            blocked_at TEXT DEFAULT (datetime('now','localtime')),
            reason     TEXT
        );
        """)

# ══════════════════════════════════════════════════════
#  数据库操作
# ══════════════════════════════════════════════════════

def upsert_session(user):
    with get_db() as db:
        db.execute("""
            INSERT INTO sessions (user_id, username, first_name, status)
            VALUES (?,?,?,'active')
            ON CONFLICT(user_id) DO UPDATE SET
                username    = excluded.username,
                first_name  = excluded.first_name,
                status      = 'active',
                started_at  = CASE WHEN status != 'active'
                              THEN datetime('now','localtime') ELSE started_at END,
                ended_at    = NULL
        """, (user.id, user.username, user.first_name))

def touch_session(user_id: int):
    with get_db() as db:
        db.execute("""
            UPDATE sessions
            SET last_msg_at = datetime('now','localtime'),
                msg_count   = msg_count + 1
            WHERE user_id = ?
        """, (user_id,))

def open_session_for(user_id: int):
    """主人主动联系时重开会话（不更新 username/first_name）"""
    with get_db() as db:
        db.execute("""
            INSERT INTO sessions (user_id, status) VALUES (?,'active')
            ON CONFLICT(user_id) DO UPDATE SET
                status     = 'active',
                started_at = CASE WHEN status != 'active'
                             THEN datetime('now','localtime') ELSE started_at END,
                ended_at   = NULL
        """, (user_id,))

def close_session(user_id: int):
    with get_db() as db:
        db.execute("""
            UPDATE sessions SET status='closed',
            ended_at=datetime('now','localtime') WHERE user_id=?
        """, (user_id,))

def is_active(user_id: int) -> bool:
    with get_db() as db:
        row = db.execute(
            "SELECT status FROM sessions WHERE user_id=?", (user_id,)
        ).fetchone()
        return row is not None and row["status"] == "active"

def get_session_info(user_id: int):
    with get_db() as db:
        return db.execute(
            "SELECT * FROM sessions WHERE user_id=?", (user_id,)
        ).fetchone()

def get_active_sessions():
    with get_db() as db:
        return db.execute(
            "SELECT * FROM sessions WHERE status='active' ORDER BY last_msg_at DESC"
        ).fetchall()

def set_reply_target(user_id: int):
    with get_db() as db:
        db.execute("""
            INSERT INTO reply_target (id, user_id) VALUES (1,?)
            ON CONFLICT(id) DO UPDATE SET user_id=excluded.user_id
        """, (user_id,))

def get_reply_target():
    with get_db() as db:
        row = db.execute("SELECT user_id FROM reply_target WHERE id=1").fetchone()
        return row["user_id"] if row else None

def clear_reply_target():
    with get_db() as db:
        db.execute("DELETE FROM reply_target WHERE id=1")

def save_msg_map(owner_msg_id: int, user_id: int):
    with get_db() as db:
        db.execute(
            "INSERT OR REPLACE INTO msg_map (owner_msg_id, user_id) VALUES (?,?)",
            (owner_msg_id, user_id),
        )

def lookup_user(owner_msg_id: int):
    with get_db() as db:
        row = db.execute(
            "SELECT user_id FROM msg_map WHERE owner_msg_id=?", (owner_msg_id,)
        ).fetchone()
        return row["user_id"] if row else None

def block_user(user_id: int, reason: str = ""):
    with get_db() as db:
        db.execute(
            "INSERT OR REPLACE INTO blocklist (user_id, reason) VALUES (?,?)",
            (user_id, reason),
        )
        db.execute(
            "UPDATE sessions SET status='blocked' WHERE user_id=?", (user_id,)
        )

def unblock_user(user_id: int):
    with get_db() as db:
        db.execute("DELETE FROM blocklist WHERE user_id=?", (user_id,))
        db.execute(
            "UPDATE sessions SET status='closed'"
            " WHERE user_id=? AND status='blocked'", (user_id,)
        )

def is_blocked(user_id: int) -> bool:
    with get_db() as db:
        return db.execute(
            "SELECT 1 FROM blocklist WHERE user_id=?", (user_id,)
        ).fetchone() is not None

def get_blocklist():
    with get_db() as db:
        return db.execute("""
            SELECT bl.user_id, bl.blocked_at, bl.reason,
                   s.first_name, s.username
            FROM blocklist bl
            LEFT JOIN sessions s ON bl.user_id = s.user_id
            ORDER BY bl.blocked_at DESC
        """).fetchall()

# ══════════════════════════════════════════════════════
#  辅助：名称 & 媒体类型
# ══════════════════════════════════════════════════════

def display_name(user) -> str:
    if ANONYMOUS_MODE:
        tag = hashlib.md5(str(user.id).encode()).hexdigest()[:8].upper()
        return f"匿名用户 #{tag}"
    parts = [p for p in [user.first_name, user.last_name] if p]
    name = " ".join(parts) or f"用户{user.id}"
    if user.username:
        name += f" (@{user.username})"
    return name

def display_name_from_row(row) -> str:
    if ANONYMOUS_MODE:
        tag = hashlib.md5(str(row["user_id"]).encode()).hexdigest()[:8].upper()
        return f"匿名用户 #{tag}"
    name = row["first_name"] or f"用户{row['user_id']}"
    if row["username"]:
        name += f" (@{row['username']})"
    return name

def msg_type_icon(msg) -> str:
    if msg.text:        return "💬"
    if msg.photo:       return "🖼"
    if msg.video:       return "🎬"
    if msg.voice:       return "🎤"
    if msg.audio:       return "🎵"
    if msg.document:    return "📎"
    if msg.sticker:     return "😄"
    if msg.video_note:  return "⭕"
    if msg.location:    return "📍"
    if msg.contact:     return "👤"
    return "📦"

def msg_type_label(msg) -> str:
    labels = {
        "text": "文字", "photo": "图片", "video": "视频",
        "voice": "语音", "audio": "音频", "document": "文件",
        "sticker": "贴纸", "video_note": "视频留言",
        "location": "位置", "contact": "联系人",
    }
    for attr, label in labels.items():
        if getattr(msg, attr, None):
            return label
    return "其他"

# ══════════════════════════════════════════════════════
#  媒体转发
# ══════════════════════════════════════════════════════

async def send_media(bot, chat_id: int, msg, extra_caption: str = ""):
    """转发一条消息的媒体内容，返回发出消息的 message_id，失败返回 None。"""
    cap = (msg.caption or "") + extra_caption
    try:
        if msg.text:
            sent = await bot.send_message(chat_id=chat_id, text=msg.text)
        elif msg.photo:
            sent = await bot.send_photo(
                chat_id=chat_id, photo=msg.photo[-1].file_id, caption=cap)
        elif msg.video:
            sent = await bot.send_video(
                chat_id=chat_id, video=msg.video.file_id, caption=cap)
        elif msg.voice:
            sent = await bot.send_voice(
                chat_id=chat_id, voice=msg.voice.file_id, caption=cap)
        elif msg.audio:
            sent = await bot.send_audio(
                chat_id=chat_id, audio=msg.audio.file_id, caption=cap)
        elif msg.document:
            sent = await bot.send_document(
                chat_id=chat_id, document=msg.document.file_id, caption=cap)
        elif msg.sticker:
            sent = await bot.send_sticker(
                chat_id=chat_id, sticker=msg.sticker.file_id)
        elif msg.video_note:
            sent = await bot.send_video_note(
                chat_id=chat_id, video_note=msg.video_note.file_id)
        elif msg.location:
            sent = await bot.send_location(
                chat_id=chat_id,
                latitude=msg.location.latitude,
                longitude=msg.location.longitude)
        elif msg.contact:
            sent = await bot.send_contact(
                chat_id=chat_id,
                phone_number=msg.contact.phone_number,
                first_name=msg.contact.first_name,
                last_name=msg.contact.last_name or "")
        else:
            return None
        return sent.message_id
    except Exception as e:
        logger.error("send_media → chat_id=%s err=%s", chat_id, e)
        return None

# ══════════════════════════════════════════════════════
#  命令处理
# ══════════════════════════════════════════════════════

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "🤖 <b>客服中转机器人 v2 已就绪</b>\n"
            "══════════════════════════\n"
            "📥 用户发来消息后你会收到卡片通知\n\n"
            "<b>📨 回复方式：</b>\n"
            "  ➤ 直接<b>回复</b>转发消息（推荐）\n"
            "  ➤ /r 用户ID — 手动指定，再直接发\n\n"
            "<b>📋 会话：</b>  /sessions · /end · /endall\n"
            "<b>🚫 黑名单：</b>/block · /unblock · /blocklist\n"
            "<b>❓ 帮助：</b>  /help"
        )
    else:
        if is_blocked(user.id):
            await update.message.reply_text("⚠️ 你无法使用此服务。")
            return
        upsert_session(user)
        await update.message.reply_html(
            f"👋 你好，<b>{user.first_name}</b>！\n\n"
            "直接发消息给我，我会帮你转达。\n"
            "对方回复后，我也会发给你。\n\n"
            "支持：文字、图片、视频、语音、文件等。\n\n"
            "/end — 结束对话   /help — 帮助"
        )


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "📖 <b>主人操作手册</b>\n"
            "══════════════════════════\n\n"
            "<b>📨 回复用户：</b>\n"
            "  长按转发消息 → 回复（自动识别用户）\n"
            "  <code>/r 用户ID</code> 手动指定，之后直接发消息\n\n"
            "<b>📋 会话管理：</b>\n"
            "  <code>/sessions</code>         查看活跃用户列表\n"
            "  <code>/r</code>                查看当前回复目标\n"
            "  <code>/r 用户ID</code>         切换回复目标\n"
            "  <code>/end 用户ID</code>       结束某用户对话\n"
            "  <code>/endall</code>           结束全部对话\n\n"
            "<b>🚫 黑名单：</b>\n"
            "  <code>/block 用户ID [原因]</code>  拉黑\n"
            "  <code>/unblock 用户ID</code>        解除拉黑\n"
            "  <code>/blocklist</code>             查看黑名单\n\n"
            "<b>📦 支持媒体类型：</b>\n"
            "  文字 · 图片 · 视频 · 语音 · 音频\n"
            "  文件 · 贴纸 · 视频留言 · 位置 · 联系人"
        )
    else:
        await update.message.reply_html(
            "📖 <b>使用说明</b>\n"
            "══════════════════════════\n\n"
            "直接发任意消息给我，我会转达给对方。\n"
            "支持：文字、图片、视频、语音、文件等。\n\n"
            "/end  — 结束当前对话\n"
            "/start — 重新开始"
        )


async def cmd_end(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user

    if user.id == OWNER_ID:
        if context.args and context.args[0].isdigit():
            uid = int(context.args[0])
        else:
            uid = get_reply_target()
        if not uid:
            await update.message.reply_text(
                "❌ 请指定用户 ID\n用法: /end 用户ID"
            ); return
        close_session(uid)
        if get_reply_target() == uid:
            clear_reply_target()
        await update.message.reply_html(
            f"✅ 已结束与用户 <code>{uid}</code> 的对话。"
        )
        try:
            await context.bot.send_message(
                chat_id=uid,
                text="📴 对话已结束。\n如需再次联系，直接发消息即可重新开始。",
            )
        except Exception: pass
    else:
        if not is_active(user.id):
            await update.message.reply_text("❌ 你当前没有活跃的对话。"); return
        close_session(user.id)
        await update.message.reply_text(
            "✅ 对话已结束。\n如需再次联系，直接发消息即可重新开始。"
        )
        try:
            await context.bot.send_message(
                chat_id=OWNER_ID,
                text=(
                    "📴 <b>用户主动结束了对话</b>\n"
                    "━━━━━━━━━━━━━━━━━━\n"
                    f"👤 {display_name(user)}\n"
                    f"🆔 <code>{user.id}</code>"
                ),
                parse_mode=constants.ParseMode.HTML,
            )
        except Exception: pass


async def cmd_endall(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    rows = get_active_sessions()
    with get_db() as db:
        db.execute(
            "UPDATE sessions SET status='closed',"
            " ended_at=datetime('now','localtime') WHERE status='active'"
        )
    clear_reply_target()
    for row in rows:
        try:
            await context.bot.send_message(
                chat_id=row["user_id"],
                text="📴 对话已结束。\n如需再次联系，直接发消息即可重新开始。",
            )
        except Exception: pass
    await update.message.reply_text(f"✅ 已结束全部 {len(rows)} 个活跃对话。")


async def cmd_sessions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    rows = get_active_sessions()
    if not rows:
        await update.message.reply_text("💤 当前没有活跃用户。"); return

    current = get_reply_target()
    lines = [f"💬 <b>活跃会话（{len(rows)} 个）</b>", "━━━━━━━━━━━━━━━━━━"]
    for r in rows:
        name = display_name_from_row(r)
        marker = "  ◀ 当前回复目标" if r["user_id"] == current else ""
        lines.append(
            f"• <b>{name}</b>{marker}\n"
            f"  🆔 <code>{r['user_id']}</code>  "
            f"📨 {r['msg_count']} 条  "
            f"🕐 {r['last_msg_at']}"
        )
    lines += [
        "━━━━━━━━━━━━━━━━━━",
        "回复转发消息，或 /r 用户ID 切换目标",
    ]
    await update.message.reply_html("\n".join(lines))


async def cmd_r(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return

    if not context.args:
        current = get_reply_target()
        if current:
            row = get_session_info(current)
            name = display_name_from_row(row) if row else f"用户{current}"
            await update.message.reply_html(
                f"🎯 <b>当前回复目标</b>\n"
                f"━━━━━━━━━━━━━━━━━━\n"
                f"👤 {name}\n"
                f"🆔 <code>{current}</code>\n\n"
                f"切换: /r 用户ID"
            )
        else:
            await update.message.reply_text(
                "❌ 尚未选定回复对象\n"
                "用法: /r 用户ID\n"
                "或直接回复某条转发消息"
            )
        return

    if not context.args[0].isdigit():
        await update.message.reply_text("❌ 用法: /r 用户ID（纯数字）"); return

    uid = int(context.args[0])
    set_reply_target(uid)
    row = get_session_info(uid)
    name = display_name_from_row(row) if row else f"用户{uid}"
    status_str = "✅ 活跃中" if is_active(uid) else "⚠️ 无活跃会话（发消息将自动重开）"
    await update.message.reply_html(
        f"🎯 <b>已切换回复目标</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"👤 {name}\n"
        f"🆔 <code>{uid}</code>  {status_str}\n\n"
        f"现在直接发消息即可发给 ta。"
    )


async def cmd_block(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return

    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text(
            "用法: /block 用户ID [原因]\n"
            "示例: /block 123456 广告骚扰"
        ); return

    uid = int(context.args[0])
    reason = " ".join(context.args[1:]) if len(context.args) > 1 else ""
    block_user(uid, reason)
    if get_reply_target() == uid:
        clear_reply_target()

    try:
        await context.bot.send_message(
            chat_id=uid, text="⛔ 你已被禁止使用此服务。"
        )
    except Exception: pass

    await update.message.reply_html(
        f"🚫 <b>已拉黑用户</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"🆔 <code>{uid}</code>"
        + (f"\n📝 原因: {reason}" if reason else "")
        + f"\n\n解除: /unblock {uid}"
    )


async def cmd_unblock(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return

    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法: /unblock 用户ID"); return

    uid = int(context.args[0])
    if not is_blocked(uid):
        await update.message.reply_html(
            f"⚠️ 用户 <code>{uid}</code> 不在黑名单中。"
        ); return

    unblock_user(uid)
    try:
        await context.bot.send_message(
            chat_id=uid, text="✅ 你已被解除限制，可以重新发送消息。"
        )
    except Exception: pass

    await update.message.reply_html(
        f"✅ 已解除用户 <code>{uid}</code> 的拉黑。"
    )


async def cmd_blocklist(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return

    rows = get_blocklist()
    if not rows:
        await update.message.reply_text("✅ 黑名单为空。"); return

    lines = [f"🚫 <b>黑名单（{len(rows)} 人）</b>", "━━━━━━━━━━━━━━━━━━"]
    for r in rows:
        name = r["first_name"] or f"用户{r['user_id']}"
        if r["username"]: name += f" (@{r['username']})"
        lines.append(
            f"• <b>{name}</b>\n"
            f"  🆔 <code>{r['user_id']}</code>  🕐 {r['blocked_at']}"
            + (f"\n  📝 {r['reason']}" if r["reason"] else "")
        )
    lines += ["━━━━━━━━━━━━━━━━━━", "解除: /unblock 用户ID"]
    await update.message.reply_html("\n".join(lines))

# ══════════════════════════════════════════════════════
#  消息转发核心
# ══════════════════════════════════════════════════════

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    msg  = update.message
    if msg is None:
        return

    # ── 主人发消息 ────────────────────────────────────
    if user.id == OWNER_ID:
        target_uid = None

        # 1. 优先：回复了某条转发消息
        if msg.reply_to_message:
            target_uid = lookup_user(msg.reply_to_message.message_id)
            if target_uid:
                set_reply_target(target_uid)

        # 2. 次选：当前设定的回复目标
        if target_uid is None:
            target_uid = get_reply_target()

        if target_uid is None:
            await msg.reply_html(
                "⚠️ <b>未选定回复对象</b>\n\n"
                "请<b>回复</b>某条转发消息，\n"
                "或用 /r 用户ID 指定目标。"
            ); return

        if is_blocked(target_uid):
            await msg.reply_html(
                f"⛔ 用户 <code>{target_uid}</code> 已被拉黑，无法发送。\n"
                f"解除: /unblock {target_uid}"
            ); return

        open_session_for(target_uid)
        sent_id = await send_media(context.bot, target_uid, msg)
        if sent_id is not None:
            await msg.reply_text("✓ 已发送", quote=True)
        else:
            await msg.reply_html(
                "❌ 发送失败\n可能原因：对方已屏蔽机器人或账号不存在"
            )
        return

    # ── 普通用户发消息 ────────────────────────────────

    # 黑名单检查
    if is_blocked(user.id):
        await msg.reply_text("⛔ 你无法使用此服务。")
        return

    # 更新会话
    upsert_session(user)
    touch_session(user.id)

    icon  = msg_type_icon(msg)
    mtype = msg_type_label(msg)

    # ── 给主人发「消息卡片」头部 ──
    header_text = (
        f"┌─ 📨 <b>新消息</b>  {icon} {mtype}\n"
        f"│  👤 {display_name(user)}\n"
    )
    if not ANONYMOUS_MODE:
        header_text += f"│  🆔 <code>{user.id}</code>\n"
    header_text += "└─────────────────────"

    try:
        header_msg = await context.bot.send_message(
            chat_id=OWNER_ID,
            text=header_text,
            parse_mode=constants.ParseMode.HTML,
        )
        # 转发实际媒体内容
        content_id = await send_media(context.bot, OWNER_ID, msg)

        # 操作按钮行
        kb = InlineKeyboardMarkup([[
            InlineKeyboardButton(
                "🎯 回复此人", callback_data=f"target_{user.id}"
            ),
            InlineKeyboardButton(
                "🚫 拉黑", callback_data=f"block_{user.id}"
            ),
        ]])
        action_msg = await context.bot.send_message(
            chat_id=OWNER_ID,
            text=f"↑ 回复: /r <code>{user.id}</code>   结束: /end <code>{user.id}</code>",
            parse_mode=constants.ParseMode.HTML,
            reply_markup=kb,
        )

        # 所有相关消息都映射到该用户
        for mid in [header_msg.message_id, content_id, action_msg.message_id]:
            if mid:
                save_msg_map(mid, user.id)

    except Exception as e:
        logger.error("转发给主人失败: %s", e)
        await msg.reply_text("❌ 消息发送失败，请稍后重试。")
        return

    await msg.reply_text("✅ 消息已发送，等待回复…", quote=True)

# ══════════════════════════════════════════════════════
#  按钮回调
# ══════════════════════════════════════════════════════

async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    if query.from_user.id != OWNER_ID:
        await query.answer("❌ 无权操作", show_alert=True); return

    data = query.data

    if data.startswith("target_"):
        uid = int(data.split("_")[1])
        set_reply_target(uid)
        row  = get_session_info(uid)
        name = display_name_from_row(row) if row else f"用户{uid}"
        await query.edit_message_text(
            f"🎯 <b>已切换回复目标</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"👤 {name}\n"
            f"🆔 <code>{uid}</code>\n\n"
            f"直接发消息即可回复 ta。\n"
            f"/end <code>{uid}</code> 结束  /block <code>{uid}</code> 拉黑",
            parse_mode=constants.ParseMode.HTML,
        )

    elif data.startswith("block_"):
        uid = int(data.split("_")[1])
        block_user(uid)
        if get_reply_target() == uid:
            clear_reply_target()
        try:
            await context.bot.send_message(
                chat_id=uid, text="⛔ 你已被禁止使用此服务。"
            )
        except Exception: pass
        await query.edit_message_text(
            f"🚫 <b>已拉黑用户</b>\n"
            f"🆔 <code>{uid}</code>\n\n"
            f"解除: /unblock <code>{uid}</code>",
            parse_mode=constants.ParseMode.HTML,
        )

# ══════════════════════════════════════════════════════
#  主入口
# ══════════════════════════════════════════════════════

def main():
    init_db()
    app = Application.builder().token(BOT_TOKEN).build()

    for name, handler in [
        ("start",     cmd_start),
        ("help",      cmd_help),
        ("end",       cmd_end),
        ("endall",    cmd_endall),
        ("sessions",  cmd_sessions),
        ("r",         cmd_r),
        ("block",     cmd_block),
        ("unblock",   cmd_unblock),
        ("blocklist", cmd_blocklist),
    ]:
        app.add_handler(CommandHandler(name, handler))

    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, handle_message))

    logger.info("🤖 机器人启动 | 主人ID=%s | 匿名=%s", OWNER_ID, ANONYMOUS_MODE)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF

    success "程序文件写入完成"
}

# ─────────────────────────── 安装流程 ───────────────────────────

setup_venv() {
    step "创建 Python 虚拟环境"
    cd "$INSTALL_DIR"
    $PYTHON_CMD -m venv venv >/dev/null 2>&1
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
    success "依赖安装完成 (python-telegram-bot 20.7)"
}

create_service() {
    step "创建 systemd 服务"
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Telegram Relay Chat Bot v2
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    success "服务已创建: ${SERVICE_NAME}"
}

create_manage_script() {
    cat > /usr/local/bin/tgbot << EOF
#!/bin/bash
case "\$1" in
    start)     systemctl start ${SERVICE_NAME}   && echo "✅ 已启动" ;;
    stop)      systemctl stop ${SERVICE_NAME}    && echo "⏹ 已停止" ;;
    restart)   systemctl restart ${SERVICE_NAME} && echo "🔄 已重启" ;;
    status)    systemctl status ${SERVICE_NAME} ;;
    log)       journalctl -u ${SERVICE_NAME} -f ;;
    uninstall)
        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        rm -rf ${INSTALL_DIR}
        rm -f /usr/local/bin/tgbot
        systemctl daemon-reload
        echo "✅ 已卸载"
        ;;
    *) echo "用法: tgbot {start|stop|restart|status|log|uninstall}" ;;
esac
EOF
    chmod +x /usr/local/bin/tgbot
    success "管理脚本已安装: tgbot"
}

start_bot() {
    step "启动机器人"
    systemctl start ${SERVICE_NAME}
    sleep 2
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        success "机器人启动成功！"
    else
        warn "启动可能有问题，请检查: tgbot log"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       🎉  安装完成！客服中转机器人 v2 已就绪        ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}安装目录:${NC}   ${INSTALL_DIR}"
    echo -e "  ${BOLD}主人 ID:${NC}    ${OWNER_ID}"
    echo -e "  ${BOLD}匿名模式:${NC}   ${ANONYMOUS_MODE}"
    echo ""
    echo -e "  ${BOLD}── 服务器管理 ──────────────────────────────${NC}"
    echo -e "    ${CYAN}tgbot start${NC}      启动"
    echo -e "    ${CYAN}tgbot stop${NC}       停止"
    echo -e "    ${CYAN}tgbot restart${NC}    重启"
    echo -e "    ${CYAN}tgbot log${NC}        实时日志"
    echo -e "    ${CYAN}tgbot uninstall${NC}  卸载"
    echo ""
    echo -e "  ${BOLD}── 主人 Telegram 命令 ──────────────────────${NC}"
    echo -e "    ${CYAN}回复转发消息${NC}             自动回复对应用户（推荐）"
    echo -e "    ${CYAN}/r 用户ID${NC}                手动切换回复目标"
    echo -e "    ${CYAN}/sessions${NC}                查看所有活跃用户"
    echo -e "    ${CYAN}/end 用户ID${NC}              结束某用户的对话"
    echo -e "    ${CYAN}/endall${NC}                  结束全部对话"
    echo -e "    ${CYAN}/block 用户ID [原因]${NC}     拉黑用户"
    echo -e "    ${CYAN}/unblock 用户ID${NC}          解除拉黑"
    echo -e "    ${CYAN}/blocklist${NC}               查看黑名单"
    echo ""
    echo -e "  ${BOLD}── 支持媒体类型 ────────────────────────────${NC}"
    echo -e "    文字 · 图片 · 视频 · 语音 · 音频"
    echo -e "    文件 · 贴纸 · 视频留言 · 位置 · 联系人"
    echo ""
    echo -e "  ${BOLD}修改配置:${NC}"
    echo -e "    ${CYAN}nano ${INSTALL_DIR}/config.py && tgbot restart${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}➜ 去 Telegram 找你的机器人，发 /start 开始！${NC}"
    echo ""
}

# ─────────────────────────── 主流程 ───────────────────────────

main() {
    banner
    check_root
    detect_os
    install_system_deps
    check_python
    collect_config
    write_files
    setup_venv
    create_service
    create_manage_script
    start_bot
    print_summary
}

main

