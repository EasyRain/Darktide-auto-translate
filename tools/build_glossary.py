"""build_glossary.py -- regenerate translations/glossary.lua from the game's own localisation.

The glossary is data the mod reads at runtime (masking + restoring official terms); this is
the only writer of it, because the hand-verified parts below are the source of truth and a
manual edit to the generated file would be lost on the next run.

    python tools/build_glossary.py
    python tools/build_glossary.py --export <dir> --uk-ref <dir>

* `--export`  the per-language term exports (translations/export/<lang>.lua in a deployed
              copy of the mod, or wherever i18n tooling wrote them)
* `--uk-ref`  the Ukrainian community translation (Nexus 618); optional - without it the
              Ukrainian values of a previous run are carried over untouched

Inputs it reads: the exports, the previous glossary.lua (values are carried over), and the
hand-verified blocks below. Output: translations/glossary.lua next to this script.
"""
import io, os, re, sys, glob, collections

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXPORT = os.path.join(REPO, 'translations', 'export')
DEFAULT_UKREF = os.environ.get('AT_UK_REF', r'D:\DshWorkSpace\Darktide\.loc_ref')


def _arg(flag, default):
    if flag in sys.argv:
        return sys.argv[sys.argv.index(flag) + 1]
    return default


EXPORT = _arg('--export', DEFAULT_EXPORT)
UKREF = _arg('--uk-ref', DEFAULT_UKREF)
OUT = os.path.join(REPO, 'translations', 'glossary.lua')

GAME_LANGS = ['en', 'zh-cn', 'zh-tw', 'ja', 'ko', 'ru', 'de', 'fr', 'es', 'it', 'pl', 'pt-br']
RICH = re.compile(r'\{#[^}]*\}')

def strip_rich(s):
    return RICH.sub('', s).replace('\\n', ' ').strip()

def parse_export(lang):
    p = os.path.join(EXPORT, lang + '.lua')
    if not os.path.exists(p):
        return {}          # exports only exist on a machine that has run the game
    t = io.open(p, encoding='utf-8').read()
    return dict(re.findall(r'\["(loc_[^"]+)"\] = "((?:[^"\\]|\\.)*)"', t))

# The file this script writes is also a source. Without this, regenerating on a
# machine whose translations/export/ is missing (or was cleaned) silently dropped
# every game-derived term - the exports are only there after the game has run.
ENTRY_RE = re.compile(r'\{\s*en = "((?:[^"\\]|\\.)*)"(.*?)\},', re.S)
FIELD_RE = re.compile(r'(?:\["([a-z]{2}(?:-[a-z]{2})?)"\]|(?<![\w"])([a-z]{2}(?:-[a-z]{2})?)) = "((?:[^"\\]|\\.)*)"')

def parse_existing(path):
    """en(lower) -> {lang: text} from a previously generated glossary."""
    out = {}
    if not os.path.exists(path):
        return out
    text = io.open(path, encoding='utf-8').read()
    for m in ENTRY_RE.finditer(text):
        en, body = m.group(1), m.group(2)
        vals = {}
        for fm in FIELD_RE.finditer(body):
            lang = fm.group(1) or fm.group(2)
            if lang and lang != 'en':
                vals[lang] = fm.group(3)
        if vals:
            out.setdefault(en.lower(), {}).update(vals)
    return out

# ---- Ukrainian: from the community mod (complete translation) ----
KEY_BLOCK = re.compile(r'\[?"?loc_keys"?\]?\s*=\s*\{([^}]*)\}')
def extract_uk(path):
    text = io.open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in KEY_BLOCK.finditer(text):
        keys = re.findall(r'"(loc_[^"]+)"', m.group(1))
        if not keys:
            continue
        seg = text[m.end():m.end() + 3000]
        rm = re.search(r'return\s+"((?:[^"\\]|\\.)*)"', seg)
        if rm:
            for k in keys:
                out.setdefault(k, rm.group(1))
    return out

uk = {}
for p in sorted(glob.glob(os.path.join(UKREF, 'ukrainian', 'UkrainianLocalization', 'scripts', 'mods', 'UkrainianLocalization', 'UkrainianLocalization_part*.lua'))):
    uk.update(extract_uk(p))

# ---- collect: key -> {lang: text} ----
data = collections.defaultdict(dict)
for lang in GAME_LANGS:
    for k, v in parse_export(lang).items():
        data[k][lang] = strip_rich(v)
for k, v in uk.items():
    if k in data:
        data[k]['uk'] = strip_rich(v)

# Words that must never become terms, however often the game uses them.
#
# Masking replaces a term everywhere it appears, which is right for a name - "Relic" is 圣物 in every
# context - and wrong for a word that carries grammar or has a second, ordinary meaning. The settings
# export this project just collected offered On, Off, All, None, Back, Save, Close, In, Out, More,
# Name, Type, Value..., and a glossary built from those would rewrite "on the ground" as the word a
# UI shows for a switch, or "close range" as the word a menu shows for a button. That corruption is
# silent: the placeholder and format-specifier guards cannot see meaning.
#
# So this list is about *function*: state words, prepositions, verbs that double as directions, and
# generic nouns that are labels for other things. Nouns and names are the point of the glossary and
# stay - "filters" was reported as mistranslated and is deliberately not here.
STOP_WORDS = {
    # state and choice
    'on', 'off', 'all', 'none', 'auto', 'automatic', 'default', 'yes', 'no', 'ok', 'true', 'false',
    'enabled', 'disabled', 'unavailable', 'available', 'always', 'never', 'optional', 'required',
    'selected', 'unselected', 'unknown', 'mixed', 'custom',
    # actions a label performs (verbs, and several of them are also directions)
    'apply', 'cancel', 'close', 'back', 'next', 'previous', 'open', 'save', 'load', 'delete',
    'add', 'edit', 'remove', 'reset', 'clear', 'confirm', 'continue', 'retry', 'skip', 'start',
    'stop', 'exit', 'quit', 'search', 'sort', 'order', 'select', 'choose', 'show', 'hide',
    'toggle', 'enable', 'disable', 'set', 'change', 'use', 'copy', 'paste', 'move',
    # place and direction
    'left', 'right', 'top', 'bottom', 'up', 'down', 'in', 'out', 'inside', 'outside', 'above',
    'below', 'front', 'rear', 'near', 'far', 'here', 'there', 'over', 'under',
    # quantity and degree
    'more', 'less', 'max', 'min', 'maximum', 'minimum', 'low', 'medium', 'high', 'normal',
    'small', 'large', 'big', 'short', 'long', 'fast', 'slow', 'new', 'old', 'first', 'last',
    # generic nouns that exist to label other things
    'name', 'title', 'text', 'value', 'values', 'type', 'types', 'size', 'mode', 'modes', 'level',
    'amount', 'number', 'count', 'total', 'info', 'information', 'help', 'about', 'other', 'others',
    'option', 'options', 'setting', 'settings', 'button', 'buttons', 'key', 'keys', 'test',
}


def is_term(text):
    if not text or len(text) < 2 or len(text) > 30:
        return False
    if text[-1] in '.!:;':
        return False
    if re.search(r'[{}%<>|]', text):
        return False
    if re.fullmatch(r'[\d\s.,%+-]+', text):
        return False
    if text.strip().lower() in STOP_WORDS:
        return False
    return True

terms = collections.OrderedDict()   # lower(en) -> entry
exported_keys = set()               # words the game itself localises
skipped = []
for k in sorted(data.keys()):
    langs = data[k]
    en = langs.get('en', '')
    if not is_term(en):
        skipped.append((k, en))
        continue
    exported_keys.add(en.lower())
    key = en.lower()
    if key in terms:
        # merge language coverage (prefer the entry with more languages)
        if len(langs) > len(terms[key]):
            terms[key] = dict(langs)
        continue
    terms[key] = dict(langs)

# ---- the string-cache harvest ----
#
# Everything above only covers key names translations/term_keys.lua contains, and the *English* value
# is what pairs a key with its target languages - which is why a term whose key nobody guessed stays
# invisible no matter how many languages are collected. The harvest files
# (exporter.harvest_cache -> translations/export/cache_<lang>.lua) point the other way: they hold
# key -> string for the keys the key list does NOT have, in whichever language the game ran.
#
# Pairing them per key turns "Renegade Berzerker" -> "血痂狂暴者" into a term as soon as an English
# harvest exists - no second collection round, and no key list entry. Nothing is invented: a key is
# used only when the English side and at least one target side both carry it, both values have to
# pass the same "is this a bare term" test the exports do, and a word the exports already carry wins.
def parse_cache(lang):
    path = os.path.join(EXPORT, 'cache_' + lang + '.lua')
    if not os.path.exists(path):
        return {}
    text = io.open(path, encoding='utf-8').read()
    return dict(re.findall(r'\["(loc_[^"]+)"\] = "((?:[^"\\]|\\.)*)"', text))

cache = {lang: parse_cache(lang) for lang in GAME_LANGS}
cache = {lang: values for lang, values in cache.items() if values}
harvested = 0
if 'en' in cache:
    for cache_key, raw in cache['en'].items():
        en = strip_rich(raw)
        if not is_term(en):
            continue
        key = en.lower()
        if key in terms or key in exported_keys:
            continue
        langs = {'en': en}
        for lang, values in cache.items():
            if lang == 'en' or cache_key not in values:
                continue
            text = strip_rich(values[cache_key])
            if is_term(text):
                langs[lang] = text
        if len(langs) > 1:
            terms[key] = langs
            exported_keys.add(key)
            harvested += 1
print('string cache: %d extra term(s) from %s'
      % (harvested, ', '.join(sorted(cache)) if cache else 'no cache_*.lua file'))

# ---- carry over whatever a previous run produced (see parse_existing) ----
#
# This happens after the hand-verified blocks are defined, because it needs to know which
# source words those blocks own: they are authoritative for their own terms, and carrying them
# in as well is how every one of them ended up in the file twice (the committed glossary had
# two copies of all ten mechanics terms, and each re-run added a copy of every hand-written
# term). The point of the carry-over is the values the current exports no longer have, e.g.
# Ukrainian, which the game never shipped.

# ---- hand verified core mechanics (no game loc key exists for these) ----
HAND = [
    ("Ability",  {"zh-cn": "能力", "zh-tw": "能力", "ja": "アビリティ", "ko": "능력"}),
    ("Aura",     {"zh-cn": "光环", "zh-tw": "光環", "ja": "オーラ", "ko": "오라"}),
    ("Blitz",    {"zh-cn": "闪击", "zh-tw": "閃擊", "ja": "電撃", "ko": "대공세"}),
    ("Keystone", {"zh-cn": "楔石", "zh-tw": "楔石", "ja": "キーストーン", "ko": "키스톤"}),
    ("Melee",    {"zh-cn": "近战", "zh-tw": "近戰", "ja": "近接", "ko": "근접", "uk": "Ближній бій"}),
    ("Ranged",   {"zh-cn": "远程", "zh-tw": "遠程", "ja": "遠隔", "ko": "원거리"}),
    ("None",     {"zh-cn": "无", "zh-tw": "無", "ja": "なし", "ko": "없음"}),
    ("Unknown",  {"zh-cn": "未知", "zh-tw": "未知", "ja": "不明", "ko": "알 수 없음"}),
    # community names for the same classes (the game's own wording is Arbitrator /
    # Skitarius, but mods often write Arbites / Skitarii)
    ("Arbites",  {"zh-cn": "法务官", "zh-tw": "法務官", "uk": "Арбітр"}),
    ("Skitarii", {"zh-cn": "护教军士兵", "zh-tw": "護教軍士兵", "uk": "Скітарій"}),
]

# ---- game terms whose loc key is not in the collected key list (yet) ----
#
# These ARE the game's own terms - the game localises them - but under key names the export has
# never resolved, and a key nobody guessed cannot be looked up (the export resolves 701 of the 1459
# names in translations/term_keys.lua and reports the other 758 as unknown). Machine translation
# then invents a wording: "Rampage!" (the Hive Scum ability, key `broker_ability_punk_rage` in
# ability_timer) came back as "大闹天宫!".
#
# The values below are the game's own wording, read out of the game itself: exporter.harvest_cache
# dumped the keys and strings its string cache held (translations/export/cache_zh-cn.lua, 221 keys
# the key list did not have) and the wording comes from those entries - a loc key the game really
# has, carrying the string the Chinese client displays. Two of them, and the mod's own key names
# line up with them one for one:
#
#     loc_talent_broker_ability_punk_rage   怒火冲天！     ability_timer: broker_ability_punk_rage
#     loc_talent_broker_ability_stimm_field 兴奋剂补给     ability_timer: broker_ability_stimm_field
#     loc_talent_broker_ability_focus       亡命之徒       ability_timer: broker_ability_focus (already
#                                                                         in the glossary from the export)
#
# The keys themselves are in translations/term_keys.lua now, so an English collection round turns
# these into ordinary exported terms - and the export then shadows this block, because it is
# authoritative for its own terms.
MISSING_LOC = [
    # Hive Scum (Broker) combat abilities. The game spells the name with its own exclamation mark,
    # and the mod writes the English that way too ("Rampage!"), so both spellings are listed: the
    # matcher prefers the longer term where it applies.
    ("Rampage!",       {"zh-cn": "怒火冲天！", "zh-tw": "怒火沖天！"}),
    ("Rampage",        {"zh-cn": "怒火冲天", "zh-tw": "怒火沖天"}),
    ("Stimm Supply",   {"zh-cn": "兴奋剂补给", "zh-tw": "興奮劑補給"}),
]

# ---- hand written interface labels, all 16 languages ----
#
# General interface wording rather than game lore: the meaning in each language is
# standard, and these are the words a settings screen is built from. They are masked
# before translation, so the offline model never sees them - which matters, because a
# label arriving on its own is exactly what it gets wrong: measured on the real model,
# "Right" came back as "這樣的情況", "Top" as "排在第一位", "Block Cost" as "区块成本".
# Masking makes a label correct in every language, whatever the engine.
UI = [
    ("Right",      {"zh-cn": "右侧", "zh-tw": "右側", "ja": "右", "ko": "오른쪽", "ru": "справа", "de": "rechts", "fr": "droite", "es": "derecha", "it": "destra", "pl": "prawo", "pt-br": "direita", "uk": "праворуч", "nl": "rechts", "sv": "höger", "tr": "sağ", "ar": "يمين"}),
    ("Left",       {"zh-cn": "左侧", "zh-tw": "左側", "ja": "左", "ko": "왼쪽", "ru": "слева", "de": "links", "fr": "gauche", "es": "izquierda", "it": "sinistra", "pl": "lewo", "pt-br": "esquerda", "uk": "ліворуч", "nl": "links", "sv": "vänster", "tr": "sol", "ar": "يسار"}),
    ("Center",     {"zh-cn": "居中", "zh-tw": "置中", "ja": "中央", "ko": "가운데", "ru": "по центру", "de": "zentriert", "fr": "centré", "es": "centrado", "it": "centrato", "pl": "wyśrodkowane", "pt-br": "centralizado", "uk": "по центру", "nl": "gecentreerd", "sv": "centrerad", "tr": "ortala", "ar": "وسط"}),
    ("Top",        {"zh-cn": "顶部", "zh-tw": "頂部", "ja": "上", "ko": "위", "ru": "сверху", "de": "oben", "fr": "haut", "es": "arriba", "it": "alto", "pl": "góra", "pt-br": "topo", "uk": "вгорі", "nl": "boven", "sv": "överst", "tr": "üst", "ar": "أعلى"}),
    ("Bottom",     {"zh-cn": "底部", "zh-tw": "底部", "ja": "下", "ko": "아래", "ru": "снизу", "de": "unten", "fr": "bas", "es": "abajo", "it": "basso", "pl": "dół", "pt-br": "base", "uk": "внизу", "nl": "onder", "sv": "nederst", "tr": "alt", "ar": "أسفل"}),
    ("Horizontal", {"zh-cn": "水平", "zh-tw": "水平", "ja": "水平", "ko": "가로", "ru": "по горизонтали", "de": "horizontal", "fr": "horizontal", "es": "horizontal", "it": "orizzontale", "pl": "poziomo", "pt-br": "horizontal", "uk": "горизонтально", "nl": "horizontaal", "sv": "vågrät", "tr": "yatay", "ar": "أفقي"}),
    ("Vertical",   {"zh-cn": "垂直", "zh-tw": "垂直", "ja": "垂直", "ko": "세로", "ru": "по вертикали", "de": "vertikal", "fr": "vertical", "es": "vertical", "it": "verticale", "pl": "pionowo", "pt-br": "vertical", "uk": "вертикально", "nl": "verticaal", "sv": "lodrät", "tr": "dikey", "ar": "عمودي"}),

    ("Apply",      {"zh-cn": "应用", "zh-tw": "套用", "ja": "適用", "ko": "적용", "ru": "применить", "de": "übernehmen", "fr": "appliquer", "es": "aplicar", "it": "applica", "pl": "zastosuj", "pt-br": "aplicar", "uk": "застосувати", "nl": "toepassen", "sv": "tillämpa", "tr": "uygula", "ar": "تطبيق"}),
    ("Cancel",     {"zh-cn": "取消", "zh-tw": "取消", "ja": "キャンセル", "ko": "취소", "ru": "отмена", "de": "abbrechen", "fr": "annuler", "es": "cancelar", "it": "annulla", "pl": "anuluj", "pt-br": "cancelar", "uk": "скасувати", "nl": "annuleren", "sv": "avbryt", "tr": "iptal", "ar": "إلغاء"}),
    ("Close",      {"zh-cn": "关闭", "zh-tw": "關閉", "ja": "閉じる", "ko": "닫기", "ru": "закрыть", "de": "schließen", "fr": "fermer", "es": "cerrar", "it": "chiudi", "pl": "zamknij", "pt-br": "fechar", "uk": "закрити", "nl": "sluiten", "sv": "stäng", "tr": "kapat", "ar": "إغلاق"}),
    ("Save",       {"zh-cn": "保存", "zh-tw": "儲存", "ja": "保存", "ko": "저장", "ru": "сохранить", "de": "speichern", "fr": "enregistrer", "es": "guardar", "it": "salva", "pl": "zapisz", "pt-br": "salvar", "uk": "зберегти", "nl": "opslaan", "sv": "spara", "tr": "kaydet", "ar": "حفظ"}),
    ("Reset",      {"zh-cn": "重置", "zh-tw": "重設", "ja": "リセット", "ko": "초기화", "ru": "сбросить", "de": "zurücksetzen", "fr": "réinitialiser", "es": "restablecer", "it": "ripristina", "pl": "resetuj", "pt-br": "redefinir", "uk": "скинути", "nl": "resetten", "sv": "återställ", "tr": "sıfırla", "ar": "إعادة تعيين"}),
    ("Default",    {"zh-cn": "默认", "zh-tw": "預設", "ja": "既定", "ko": "기본값", "ru": "по умолчанию", "de": "Standard", "fr": "par défaut", "es": "predeterminado", "it": "predefinito", "pl": "domyślne", "pt-br": "padrão", "uk": "за замовчуванням", "nl": "standaard", "sv": "standard", "tr": "varsayılan", "ar": "افتراضي"}),
    ("Back",       {"zh-cn": "返回", "zh-tw": "返回", "ja": "戻る", "ko": "뒤로", "ru": "назад", "de": "zurück", "fr": "retour", "es": "atrás", "it": "indietro", "pl": "wstecz", "pt-br": "voltar", "uk": "назад", "nl": "terug", "sv": "tillbaka", "tr": "geri", "ar": "رجوع"}),
    ("Next",       {"zh-cn": "下一步", "zh-tw": "下一步", "ja": "次へ", "ko": "다음", "ru": "далее", "de": "weiter", "fr": "suivant", "es": "siguiente", "it": "avanti", "pl": "dalej", "pt-br": "próximo", "uk": "далі", "nl": "volgende", "sv": "nästa", "tr": "ileri", "ar": "التالي"}),
    ("Done",       {"zh-cn": "完成", "zh-tw": "完成", "ja": "完了", "ko": "완료", "ru": "готово", "de": "fertig", "fr": "terminé", "es": "hecho", "it": "fatto", "pl": "gotowe", "pt-br": "concluído", "uk": "готово", "nl": "gereed", "sv": "klar", "tr": "tamam", "ar": "تم"}),

    ("Enable",     {"zh-cn": "启用", "zh-tw": "啟用", "ja": "有効化", "ko": "활성화", "ru": "включить", "de": "aktivieren", "fr": "activer", "es": "activar", "it": "abilita", "pl": "włącz", "pt-br": "ativar", "uk": "увімкнути", "nl": "inschakelen", "sv": "aktivera", "tr": "etkinleştir", "ar": "تمكين"}),
    ("Disable",    {"zh-cn": "禁用", "zh-tw": "停用", "ja": "無効化", "ko": "비활성화", "ru": "отключить", "de": "deaktivieren", "fr": "désactiver", "es": "desactivar", "it": "disabilita", "pl": "wyłącz", "pt-br": "desativar", "uk": "вимкнути", "nl": "uitschakelen", "sv": "inaktivera", "tr": "devre dışı bırak", "ar": "تعطيل"}),
    ("Show",       {"zh-cn": "显示", "zh-tw": "顯示", "ja": "表示", "ko": "표시", "ru": "показать", "de": "anzeigen", "fr": "afficher", "es": "mostrar", "it": "mostra", "pl": "pokaż", "pt-br": "mostrar", "uk": "показати", "nl": "tonen", "sv": "visa", "tr": "göster", "ar": "إظهار"}),
    ("Hide",       {"zh-cn": "隐藏", "zh-tw": "隱藏", "ja": "非表示", "ko": "숨기기", "ru": "скрыть", "de": "ausblenden", "fr": "masquer", "es": "ocultar", "it": "nascondi", "pl": "ukryj", "pt-br": "ocultar", "uk": "приховати", "nl": "verbergen", "sv": "dölj", "tr": "gizle", "ar": "إخفاء"}),

    ("Position",   {"zh-cn": "位置", "zh-tw": "位置", "ja": "位置", "ko": "위치", "ru": "позиция", "de": "Position", "fr": "position", "es": "posición", "it": "posizione", "pl": "pozycja", "pt-br": "posição", "uk": "позиція", "nl": "positie", "sv": "position", "tr": "konum", "ar": "موضع"}),
    ("Size",       {"zh-cn": "大小", "zh-tw": "大小", "ja": "サイズ", "ko": "크기", "ru": "размер", "de": "Größe", "fr": "taille", "es": "tamaño", "it": "dimensione", "pl": "rozmiar", "pt-br": "tamanho", "uk": "розмір", "nl": "grootte", "sv": "storlek", "tr": "boyut", "ar": "حجم"}),
    ("Width",      {"zh-cn": "宽度", "zh-tw": "寬度", "ja": "幅", "ko": "너비", "ru": "ширина", "de": "Breite", "fr": "largeur", "es": "ancho", "it": "larghezza", "pl": "szerokość", "pt-br": "largura", "uk": "ширина", "nl": "breedte", "sv": "bredd", "tr": "genişlik", "ar": "عرض"}),
    ("Height",     {"zh-cn": "高度", "zh-tw": "高度", "ja": "高さ", "ko": "높이", "ru": "высота", "de": "Höhe", "fr": "hauteur", "es": "altura", "it": "altezza", "pl": "wysokość", "pt-br": "altura", "uk": "висота", "nl": "hoogte", "sv": "höjd", "tr": "yükseklik", "ar": "ارتفاع"}),
    ("Color",      {"zh-cn": "颜色", "zh-tw": "顏色", "ja": "色", "ko": "색상", "ru": "цвет", "de": "Farbe", "fr": "couleur", "es": "color", "it": "colore", "pl": "kolor", "pt-br": "cor", "uk": "колір", "nl": "kleur", "sv": "färg", "tr": "renk", "ar": "لون"}),
    ("Opacity",    {"zh-cn": "不透明度", "zh-tw": "不透明度", "ja": "不透明度", "ko": "불투명도", "ru": "непрозрачность", "de": "Deckkraft", "fr": "opacité", "es": "opacidad", "it": "opacità", "pl": "krycie", "pt-br": "opacidade", "uk": "непрозорість", "nl": "dekking", "sv": "opacitet", "tr": "opaklık", "ar": "العتامة"}),
    ("Scale",      {"zh-cn": "缩放", "zh-tw": "縮放", "ja": "拡大縮小", "ko": "크기 조정", "ru": "масштаб", "de": "Skalierung", "fr": "échelle", "es": "escala", "it": "scala", "pl": "skala", "pt-br": "escala", "uk": "масштаб", "nl": "schaal", "sv": "skala", "tr": "ölçek", "ar": "مقياس"}),
    ("Speed",      {"zh-cn": "速度", "zh-tw": "速度", "ja": "速度", "ko": "속도", "ru": "скорость", "de": "Geschwindigkeit", "fr": "vitesse", "es": "velocidad", "it": "velocità", "pl": "prędkość", "pt-br": "velocidade", "uk": "швидкість", "nl": "snelheid", "sv": "hastighet", "tr": "hız", "ar": "سرعة"}),
    ("Delay",      {"zh-cn": "延迟", "zh-tw": "延遲", "ja": "遅延", "ko": "지연", "ru": "задержка", "de": "Verzögerung", "fr": "délai", "es": "retardo", "it": "ritardo", "pl": "opóźnienie", "pt-br": "atraso", "uk": "затримка", "nl": "vertraging", "sv": "fördröjning", "tr": "gecikme", "ar": "تأخير"}),
    ("Volume",     {"zh-cn": "音量", "zh-tw": "音量", "ja": "音量", "ko": "볼륨", "ru": "громкость", "de": "Lautstärke", "fr": "volume", "es": "volumen", "it": "volume", "pl": "głośność", "pt-br": "volume", "uk": "гучність", "nl": "volume", "sv": "volym", "tr": "ses", "ar": "مستوى الصوت"}),

    ("Settings",   {"zh-cn": "设置", "zh-tw": "設定", "ja": "設定", "ko": "설정", "ru": "настройки", "de": "Einstellungen", "fr": "paramètres", "es": "ajustes", "it": "impostazioni", "pl": "ustawienia", "pt-br": "configurações", "uk": "налаштування", "nl": "instellingen", "sv": "inställningar", "tr": "ayarlar", "ar": "الإعدادات"}),
    ("Options",    {"zh-cn": "选项", "zh-tw": "選項", "ja": "オプション", "ko": "옵션", "ru": "параметры", "de": "Optionen", "fr": "options", "es": "opciones", "it": "opzioni", "pl": "opcje", "pt-br": "opções", "uk": "параметри", "nl": "opties", "sv": "alternativ", "tr": "seçenekler", "ar": "خيارات"}),
    ("Help",       {"zh-cn": "帮助", "zh-tw": "說明", "ja": "ヘルプ", "ko": "도움말", "ru": "справка", "de": "Hilfe", "fr": "aide", "es": "ayuda", "it": "aiuto", "pl": "pomoc", "pt-br": "ajuda", "uk": "довідка", "nl": "help", "sv": "hjälp", "tr": "yardım", "ar": "مساعدة"}),
    ("Warning",    {"zh-cn": "警告", "zh-tw": "警告", "ja": "警告", "ko": "경고", "ru": "предупреждение", "de": "Warnung", "fr": "avertissement", "es": "advertencia", "it": "avviso", "pl": "ostrzeżenie", "pt-br": "aviso", "uk": "попередження", "nl": "waarschuwing", "sv": "varning", "tr": "uyarı", "ar": "تحذير"}),
    ("Error",      {"zh-cn": "错误", "zh-tw": "錯誤", "ja": "エラー", "ko": "오류", "ru": "ошибка", "de": "Fehler", "fr": "erreur", "es": "error", "it": "errore", "pl": "błąd", "pt-br": "erro", "uk": "помилка", "nl": "fout", "sv": "fel", "tr": "hata", "ar": "خطأ"}),

    ("Select",     {"zh-cn": "选择", "zh-tw": "選擇", "ja": "選択", "ko": "선택", "ru": "выбрать", "de": "auswählen", "fr": "sélectionner", "es": "seleccionar", "it": "seleziona", "pl": "wybierz", "pt-br": "selecionar", "uk": "вибрати", "nl": "selecteren", "sv": "välj", "tr": "seç", "ar": "تحديد"}),
    ("Delete",     {"zh-cn": "删除", "zh-tw": "刪除", "ja": "削除", "ko": "삭제", "ru": "удалить", "de": "löschen", "fr": "supprimer", "es": "eliminar", "it": "elimina", "pl": "usuń", "pt-br": "excluir", "uk": "видалити", "nl": "verwijderen", "sv": "radera", "tr": "sil", "ar": "حذف"}),
    ("Toggle",     {"zh-cn": "切换", "zh-tw": "切換", "ja": "切り替え", "ko": "전환", "ru": "переключить", "de": "umschalten", "fr": "basculer", "es": "alternar", "it": "alterna", "pl": "przełącz", "pt-br": "alternar", "uk": "перемкнути", "nl": "schakelen", "sv": "växla", "tr": "değiştir", "ar": "تبديل"}),
    ("Hotkey",     {"zh-cn": "快捷键", "zh-tw": "快捷鍵", "ja": "ホットキー", "ko": "단축키", "ru": "горячая клавиша", "de": "Tastenkürzel", "fr": "raccourci", "es": "tecla rápida", "it": "tasto di scelta rapida", "pl": "skrót klawiszowy", "pt-br": "tecla de atalho", "uk": "гаряча клавіша", "nl": "sneltoets", "sv": "snabbtangent", "tr": "kısayol tuşu", "ar": "مفتاح اختصار"}),
    ("Font",       {"zh-cn": "字体", "zh-tw": "字體", "ja": "フォント", "ko": "글꼴", "ru": "шрифт", "de": "Schriftart", "fr": "police", "es": "fuente", "it": "carattere", "pl": "czcionka", "pt-br": "fonte", "uk": "шрифт", "nl": "lettertype", "sv": "typsnitt", "tr": "yazı tipi", "ar": "خط"}),
]

# ---- language names ----
#
# A language list is where machine translation fails where the player notices: "German"
# comes back as a nationality, "Chinese" loses Simplified/Traditional, and a lone word is
# exactly what the offline model mangles into a sentence. Mod UIs write those names in two
# conventions and both are covered here:
#
#   * the English name ("German") -> the name in the target language (德语 / ドイツ語 / Немецкий)
#   * the autonym ("Deutsch")    -> itself, in every language, so a list written in autonyms
#     (the Steam convention: English / Deutsch / 日本語 / 简体中文) stays an autonym list
#     instead of turning into a translated one. Those terms exist only to keep the word away
#     from the translator, which is also why they need no per-language data.
#
# Language codes are deliberately absent. Two letters are ordinary words elsewhere (French
# "en", Portuguese "de", Spanish "es") and the matcher ignores case, so masking them would
# wreck prose. "English" is the one name that is also its own autonym; it is handled as a
# name (a Chinese UI reads 英语), since the alternative would be two terms for one word.
LANG_NAMES = {
    #        zh-cn            zh-tw            ja                 ko              ru                    de                          fr                  es                     it                  pl                    pt-br                       uk                          nl                       sv                     tr                        ar
    "en":    {"zh-cn": "英语", "zh-tw": "英語", "ja": "英語", "ko": "영어", "ru": "английский", "de": "Englisch", "fr": "anglais", "es": "inglés", "it": "inglese", "pl": "angielski", "pt-br": "inglês", "uk": "англійська", "nl": "Engels", "sv": "engelska", "tr": "İngilizce", "ar": "الإنجليزية"},
    "zh-cn": {"zh-cn": "简体中文", "zh-tw": "簡體中文", "ja": "簡体字中国語", "ko": "중국어(간체)", "ru": "китайский (упрощённый)", "de": "Chinesisch (vereinfacht)", "fr": "chinois simplifié", "es": "chino simplificado", "it": "cinese semplificato", "pl": "chiński uproszczony", "pt-br": "chinês simplificado", "uk": "китайська (спрощена)", "nl": "Vereenvoudigd Chinees", "sv": "förenklad kinesiska", "tr": "Basitleştirilmiş Çince", "ar": "الصينية المبسطة"},
    "zh-tw": {"zh-cn": "繁体中文", "zh-tw": "繁體中文", "ja": "繁体字中国語", "ko": "중국어(번체)", "ru": "китайский (традиционный)", "de": "Chinesisch (traditionell)", "fr": "chinois traditionnel", "es": "chino tradicional", "it": "cinese tradizionale", "pl": "chiński tradycyjny", "pt-br": "chinês tradicional", "uk": "китайська (традиційна)", "nl": "Traditioneel Chinees", "sv": "traditionell kinesiska", "tr": "Geleneksel Çince", "ar": "الصينية التقليدية"},
    "zh":    {"zh-cn": "中文", "zh-tw": "中文", "ja": "中国語", "ko": "중국어", "ru": "китайский", "de": "Chinesisch", "fr": "chinois", "es": "chino", "it": "cinese", "pl": "chiński", "pt-br": "chinês", "uk": "китайська", "nl": "Chinees", "sv": "kinesiska", "tr": "Çince", "ar": "الصينية"},
    "ja":    {"zh-cn": "日语", "zh-tw": "日語", "ja": "日本語", "ko": "일본어", "ru": "японский", "de": "Japanisch", "fr": "japonais", "es": "japonés", "it": "giapponese", "pl": "japoński", "pt-br": "japonês", "uk": "японська", "nl": "Japans", "sv": "japanska", "tr": "Japonca", "ar": "اليابانية"},
    "ko":    {"zh-cn": "韩语", "zh-tw": "韓語", "ja": "韓国語", "ko": "한국어", "ru": "корейский", "de": "Koreanisch", "fr": "coréen", "es": "coreano", "it": "coreano", "pl": "koreański", "pt-br": "coreano", "uk": "корейська", "nl": "Koreaans", "sv": "koreanska", "tr": "Korece", "ar": "الكورية"},
    "ru":    {"zh-cn": "俄语", "zh-tw": "俄語", "ja": "ロシア語", "ko": "러시아어", "ru": "русский", "de": "Russisch", "fr": "russe", "es": "ruso", "it": "russo", "pl": "rosyjski", "pt-br": "russo", "uk": "російська", "nl": "Russisch", "sv": "ryska", "tr": "Rusça", "ar": "الروسية"},
    "de":    {"zh-cn": "德语", "zh-tw": "德語", "ja": "ドイツ語", "ko": "독일어", "ru": "немецкий", "de": "Deutsch", "fr": "allemand", "es": "alemán", "it": "tedesco", "pl": "niemiecki", "pt-br": "alemão", "uk": "німецька", "nl": "Duits", "sv": "tyska", "tr": "Almanca", "ar": "الألمانية"},
    "fr":    {"zh-cn": "法语", "zh-tw": "法語", "ja": "フランス語", "ko": "프랑스어", "ru": "французский", "de": "Französisch", "fr": "français", "es": "francés", "it": "francese", "pl": "francuski", "pt-br": "francês", "uk": "французька", "nl": "Frans", "sv": "franska", "tr": "Fransızca", "ar": "الفرنسية"},
    "es":    {"zh-cn": "西班牙语", "zh-tw": "西班牙語", "ja": "スペイン語", "ko": "스페인어", "ru": "испанский", "de": "Spanisch", "fr": "espagnol", "es": "español", "it": "spagnolo", "pl": "hiszpański", "pt-br": "espanhol", "uk": "іспанська", "nl": "Spaans", "sv": "spanska", "tr": "İspanyolca", "ar": "الإسبانية"},
    "it":    {"zh-cn": "意大利语", "zh-tw": "義大利語", "ja": "イタリア語", "ko": "이탈리아어", "ru": "итальянский", "de": "Italienisch", "fr": "italien", "es": "italiano", "it": "italiano", "pl": "włoski", "pt-br": "italiano", "uk": "італійська", "nl": "Italiaans", "sv": "italienska", "tr": "İtalyanca", "ar": "الإيطالية"},
    "pl":    {"zh-cn": "波兰语", "zh-tw": "波蘭語", "ja": "ポーランド語", "ko": "폴란드어", "ru": "польский", "de": "Polnisch", "fr": "polonais", "es": "polaco", "it": "polacco", "pl": "polski", "pt-br": "polonês", "uk": "польська", "nl": "Pools", "sv": "polska", "tr": "Lehçe", "ar": "البولندية"},
    "pt":    {"zh-cn": "葡萄牙语", "zh-tw": "葡萄牙語", "ja": "ポルトガル語", "ko": "포르투갈어", "ru": "португальский", "de": "Portugiesisch", "fr": "portugais", "es": "portugués", "it": "portoghese", "pl": "portugalski", "pt-br": "português", "uk": "португальська", "nl": "Portugees", "sv": "portugisiska", "tr": "Portekizce", "ar": "البرتغالية"},
    "pt-br": {"zh-cn": "巴西葡萄牙语", "zh-tw": "巴西葡萄牙語", "ja": "ブラジルポルトガル語", "ko": "브라질 포르투갈어", "ru": "бразильский португальский", "de": "Brasilianisches Portugiesisch", "fr": "portugais brésilien", "es": "portugués de Brasil", "it": "portoghese brasiliano", "pl": "portugalski (Brazylia)", "pt-br": "português (Brasil)", "uk": "бразильська португальська", "nl": "Braziliaans-Portugees", "sv": "brasiliansk portugisiska", "tr": "Brezilya Portekizcesi", "ar": "البرتغالية البرازيلية"},
    "uk":    {"zh-cn": "乌克兰语", "zh-tw": "烏克蘭語", "ja": "ウクライナ語", "ko": "우크라이나어", "ru": "украинский", "de": "Ukrainisch", "fr": "ukrainien", "es": "ucraniano", "it": "ucraino", "pl": "ukraiński", "pt-br": "ucraniano", "uk": "українська", "nl": "Oekraïens", "sv": "ukrainska", "tr": "Ukraynaca", "ar": "الأوكرانية"},
    "nl":    {"zh-cn": "荷兰语", "zh-tw": "荷蘭語", "ja": "オランダ語", "ko": "네덜란드어", "ru": "нидерландский", "de": "Niederländisch", "fr": "néerlandais", "es": "neerlandés", "it": "olandese", "pl": "niderlandzki", "pt-br": "holandês", "uk": "нідерландська", "nl": "Nederlands", "sv": "nederländska", "tr": "Hollandaca", "ar": "الهولندية"},
    "sv":    {"zh-cn": "瑞典语", "zh-tw": "瑞典語", "ja": "スウェーデン語", "ko": "스웨덴어", "ru": "шведский", "de": "Schwedisch", "fr": "suédois", "es": "sueco", "it": "svedese", "pl": "szwedzki", "pt-br": "sueco", "uk": "шведська", "nl": "Zweeds", "sv": "svenska", "tr": "İsveççe", "ar": "السويدية"},
    "tr":    {"zh-cn": "土耳其语", "zh-tw": "土耳其語", "ja": "トルコ語", "ko": "터키어", "ru": "турецкий", "de": "Türkisch", "fr": "turc", "es": "turco", "it": "turco", "pl": "turecki", "pt-br": "turco", "uk": "турецька", "nl": "Turks", "sv": "turkiska", "tr": "Türkçe", "ar": "التركية"},
    "ar":    {"zh-cn": "阿拉伯语", "zh-tw": "阿拉伯語", "ja": "アラビア語", "ko": "아랍어", "ru": "арабский", "de": "Arabisch", "fr": "arabe", "es": "árabe", "it": "arabo", "pl": "arabski", "pt-br": "árabe", "uk": "арабська", "nl": "Arabisch", "sv": "arabiska", "tr": "Arapça", "ar": "العربية"},
}

# How a mod UI actually spells each of them (several spellings where both are common).
LANG_SOURCES = [
    ("English", "en"),
    ("Chinese", "zh"),
    ("Chinese (Simplified)", "zh-cn"), ("Simplified Chinese", "zh-cn"),
    ("Chinese (Traditional)", "zh-tw"), ("Traditional Chinese", "zh-tw"),
    ("Japanese", "ja"),
    ("Korean", "ko"),
    ("Russian", "ru"),
    ("German", "de"),
    ("French", "fr"),
    ("Spanish", "es"),
    ("Italian", "it"),
    ("Polish", "pl"),
    ("Portuguese", "pt"),
    ("Brazilian Portuguese", "pt-br"), ("Portuguese (Brazil)", "pt-br"),
    ("Ukrainian", "uk"),
    ("Dutch", "nl"),
    ("Swedish", "sv"),
    ("Turkish", "tr"),
    ("Arabic", "ar"),
]

LANGS = [(name, dict(LANG_NAMES[key])) for name, key in LANG_SOURCES]

# Autonyms: written in their own script, kept exactly as they are in every language. Only the
# languages this project deals with, plus the ones mod lists commonly carry.
AUTONYMS = [
    "简体中文", "繁體中文", "中文", "日本語", "한국어", "Русский", "Deutsch", "Français",
    "Español", "Italiano", "Polski", "Português", "Português (Brasil)", "Українська",
    "Nederlands", "Svenska", "Türkçe", "العربية",
    "Čeština", "Dansk", "Suomi", "Ελληνικά", "Magyar", "Norsk", "Română", "ไทย",
    "Tiếng Việt", "Bahasa Indonesia", "עברית",
]

# ---- carry over whatever a previous run produced ----
#
# Values the current exports no longer carry have to survive a regeneration (Ukrainian, which
# the game never shipped, is the reason this exists). Source words the hand-verified blocks
# own are skipped: those blocks are authoritative for their own terms, and carrying them in as
# well is how every one of them ended up in the file twice - the committed glossary had two
# copies of all ten mechanics terms, and each re-run added a copy of every hand-written term.
hand_keys = set()
for en, _ in HAND + MISSING_LOC + UI + LANGS:
    hand_keys.add(en.lower())
for text in AUTONYMS:
    hand_keys.add(text.lower())

for en, vals in parse_existing(OUT).items():
    if en in hand_keys:
        continue
    entry = terms.setdefault(en, {})
    for lang, value in vals.items():
        entry.setdefault(lang, value)
    entry.setdefault('en', en)


def quote(s):
    s = str(s).replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ').replace('\r', '')
    return '"' + s + '"'

# Languages the engine can translate into. The game ships twelve; Ukrainian comes from
# the community mod, and the last four are the ones Lingua Imperialis carries.
EXTRA_LANGS = ['nl', 'sv', 'tr', 'ar']
LANG_ORDER = GAME_LANGS + ['uk'] + EXTRA_LANGS
LANG_KEY = {'zh-cn': '["zh-cn"]', 'zh-tw': '["zh-tw"]', 'pt-br': '["pt-br"]'}

lines = []
lines.append('-- Auto Translate glossary (generated + hand verified).')
lines.append('--')
lines.append('-- How it works: matching terms are replaced by placeholders before a text is')
lines.append('-- translated and restored afterwards, so "Keystone" cannot become "corner stone".')
lines.append('--')
lines.append('-- Sources:')
lines.append('--   * everything below the hand verified block comes from the game\'s own')
lines.append('--     localisation, exported for 12 languages at runtime (see translations/export/)')
lines.append('--   * Ukrainian values were extracted from the complete community translation')
lines.append('--     "Ukrainian Localization" (Nexus 618); the game ships no Ukrainian itself')
lines.append('--   * the hand verified block lists mechanics wording that has no loc key of its')
lines.append('--     own (Blitz / Keystone / Aura / ...), taken from the official wording')
lines.append('--')
lines.append('-- A term is only used for languages that have a value; empty ones are skipped.')
lines.append('--')
lines.append('-- NOTE: this file is generated by i18n/build_glossary.py (from the runtime exports')
lines.append('-- in translations/export/ plus the hand verified block in that script). Re-run it')
lines.append('-- after adding languages or keys — manual edits to this file will be overwritten.')
lines.append('return {')
lines.append('    terms = {')
lines.append('        -- hand verified core mechanics (no game loc key exists for these)')
# `emitted` records what the hand-verified blocks actually wrote, so the exported section
# below cannot write the same source word a second time - which is why the file used to carry
# a duplicate of every hand-written term, and one more after every re-run.
emitted = set()
for en, vals in HAND:
    emitted.add(en.lower())
    parts = ['en = ' + quote(en)]
    for lang in LANG_ORDER:
        if lang in vals:
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(vals[lang]))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('')
lines.append('        -- game terms whose own loc key is not in the collected key list (yet); the game\'s')
lines.append('        -- wording, checked against the export where the export has the term')
# Same rule as the UI labels below: once an export really resolves the key that carries this term,
# the game's wording is authoritative and this entry steps aside - the block is only a stand-in for
# a key the key list is missing, so it has to disappear by itself when the key arrives.
missing_used = 0
missing_shadowed = []
for en, vals in MISSING_LOC:
    if en.lower() in exported_keys:
        missing_shadowed.append(en)
        continue
    missing_used += 1
    emitted.add(en.lower())
    parts = ['en = ' + quote(en)]
    for lang in LANG_ORDER:
        if lang in vals:
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(vals[lang]))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('')
lines.append('        -- hand written interface labels (general UI words, 16 languages)')
# A word the game itself localises keeps the game's wording: those entries came from
# the exports and are authoritative, so the hand written value is only a fallback for
# words the game has no string for.
ui_used = 0
ui_shadowed = []
for en, vals in UI:
    if en.lower() in exported_keys:
        ui_shadowed.append(en)
        continue
    ui_used += 1
    emitted.add(en.lower())
    parts = ['en = ' + quote(en)]
    for lang in LANG_ORDER:
        if lang in vals:
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(vals[lang]))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('')
lines.append('        -- language names: the English spelling -> the name in the target language')
# Same rule as the UI labels: a word the game localises itself keeps the game's wording.
langs_used = 0
lang_shadowed = []
for en, vals in LANGS:
    if en.lower() in exported_keys:
        lang_shadowed.append(en)
        continue
    langs_used += 1
    emitted.add(en.lower())
    parts = ['en = ' + quote(en)]
    for lang in LANG_ORDER:
        if lang in vals:
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(vals[lang]))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('')
lines.append('        -- autonyms (a language in its own words), kept as written in every language')
# Deliberately not run through the shadow check above: the value here is the word itself,
# which is "do not translate this", not "use the game's wording for this".
for text in AUTONYMS:
    emitted.add(text.lower())
    parts = ['en = ' + quote(text)]
    for lang in LANG_ORDER:
        if lang != 'en':
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(text))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('')
lines.append('        -- exported from the game\'s localisation (12 languages) + Ukrainian community mod')
for key, langs in sorted(terms.items()):
    if key in emitted:
        continue              # a hand-verified block already wrote this source word
    en = langs.get('en', '')
    parts = ['en = ' + quote(en)]
    for lang in LANG_ORDER:
        if lang == 'en':
            continue          # already emitted above
        v = langs.get(lang)
        if v:
            parts.append((LANG_KEY.get(lang, lang)) + ' = ' + quote(v))
    lines.append('        { ' + ', '.join(parts) + ' },')
lines.append('    },')
lines.append('}')
lines.append('')

io.open(OUT, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))

print('generated %d terms (%d hand verified mechanics + %d uncollected game terms + %d hand written UI labels + %d language names + %d autonyms), skipped %d keys'
      % (len(terms), len(HAND), missing_used, ui_used, langs_used, len(AUTONYMS), len(skipped)))
if missing_shadowed:
    print('uncollected game terms the export now has (kept the game wording): %s'
          % ', '.join(missing_shadowed))
if ui_shadowed:
    print('UI labels the game already localises (kept the game wording): %s'
          % ', '.join(ui_shadowed))
if lang_shadowed:
    print('language names the game already localises (kept the game wording): %s'
          % ', '.join(lang_shadowed))
multi = sum(1 for l in terms.values() if len(l) >= 12)
print('terms with >=12 languages: %d' % multi)
print('\n--- skipped (not a bare term) ---')
for k, en in skipped[:12]:
    print('  %-52s en=%s' % (k, en[:40]))
print('\n--- sample ---')
for key in list(sorted(terms.keys()))[:10]:
    l = terms[key]
    print('  %-22s zh=%-8s ja=%-10s ru=%-14s uk=%s' % (l.get('en', '')[:20], l.get('zh-cn', '-')[:8], l.get('ja', '-')[:8], l.get('ru', '-')[:12], l.get('uk', '-')[:14]))
