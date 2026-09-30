"""build_glossary.py -- regenerate translations/glossary.lua from the game's own localisation.

The glossary is data the mod reads at runtime (masking + restoring official terms); this is
the only writer of it, because the hand-verified parts below are the source of truth and a
manual edit to the generated file would be lost on the next run.

    python tools/build_glossary.py
    python tools/build_glossary.py --index <db> --uk-ref <dir>

* `--index`   the localisation index (game-data/index/localization.sqlite). Every key in
              translations/term_keys.lua is looked up there and its wording taken for all twelve
              languages at once. Rebuild the index after a game update - see game-data/README.md.
* `--uk-ref`  the Ukrainian community translation (Nexus 618); optional - without it the
              Ukrainian values of a previous run are carried over untouched

Inputs it reads: the index, translations/term_keys.lua (the key list), the previous glossary.lua
(values are carried over), and the hand-verified blocks below. Output: translations/glossary.lua.
"""
import io, os, re, sys, glob, collections

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_INDEX = os.path.join(os.path.dirname(os.path.dirname(REPO)), 'game-data', 'index', 'localization.sqlite')
TERM_KEYS = os.path.join(REPO, 'translations', 'term_keys.lua')
SKILL_SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(REPO)), '.dsh', 'skills',
                             'darktide-localization-search', 'scripts')
DEFAULT_UKREF = os.environ.get('AT_UK_REF', r'D:\DshWorkSpace\Darktide\refs\localizations')


def _arg(flag, default):
    if flag in sys.argv:
        return sys.argv[sys.argv.index(flag) + 1]
    return default


INDEX = _arg('--index', DEFAULT_INDEX)
UKREF = _arg('--uk-ref', DEFAULT_UKREF)
OUT = os.path.join(REPO, 'translations', 'glossary.lua')

GAME_LANGS = ['en', 'zh-cn', 'zh-tw', 'ja', 'ko', 'ru', 'de', 'fr', 'es', 'it', 'pl', 'pt-br']
RICH = re.compile(r'\{#[^}]*\}')

def strip_rich(s):
    return RICH.sub('', s).replace('\\n', ' ').strip()

def unescape_lua(s):
    """Decode the escapes of a Lua string literal, except \\n which strip_rich turns into a space.

    The exports, the harvest files and the generated glossary are all Lua literals, and the regexes
    below capture their text verbatim: without this, the game's `"Devil's Claw" Sword` arrived as
    `\\"Devil's Claw\\" Sword` and became a term with backslashes in it, which matches nothing.
    """
    out = []
    i = 0
    while i < len(s):
        char = s[i]
        if char == '\\' and i + 1 < len(s) and s[i + 1] in ('"', '\\'):
            out.append(s[i + 1])
            i += 2
            continue
        out.append(char)
        i += 1
    return ''.join(out)

def load_index(path, keys_path):
    """key -> {lang: text}, read straight out of the localisation index.

    Why the index and not the game: the mod used to export the wording of the current language at
    startup, which meant twelve launches (one per language) to collect a key list, and a key only
    ever got a value if a round ran *after* it was added to the list. The index holds every string the
    game ships, for all twelve languages at once, keyed by the hash Fatshark computes over the key's
    UTF-8 bytes - so the glossary can be built offline, and rebuilding it after a game update costs
    one extraction (see game-data/README.md) instead of twelve rounds.

    Keys that the game does not have (mod-only keys, or names a mod invented) simply produce no row
    and are skipped, exactly as the exporter skipped them.
    """
    sys.path.insert(0, SKILL_SCRIPTS)
    from common import key_hash
    import sqlite3

    keys = sorted(set(re.findall(r'"(loc_[a-z0-9_\-]+)"',
                                 io.open(keys_path, encoding='utf-8').read())))
    if not keys:
        print('no keys in %s' % keys_path)
        return collections.defaultdict(dict)
    if not os.path.exists(path):
        print('the index is missing: %s' % path)
        print('build it first - see game-data/README.md (extract, convert, build_index)')
        raise SystemExit(2)

    con = sqlite3.connect('file:%s?mode=ro' % path, uri=True)
    cols = ', '.join('"%s"' % lang for lang in GAME_LANGS)
    out = collections.defaultdict(dict)
    found = 0
    for key in keys:
        row = con.execute('SELECT %s FROM localization WHERE hash = ? LIMIT 1' % cols,
                          (key_hash(key),)).fetchone()
        if not row:
            continue
        langs = {lang: strip_rich(value) for lang, value in zip(GAME_LANGS, row) if value}
        if langs:
            out[key] = langs
            found += 1
    print('index: %d of %d key(s) resolved (%s)' % (found, len(keys), os.path.basename(path)))
    return out

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
                vals[lang] = unescape_lua(fm.group(3))
        if vals:
            out.setdefault(unescape_lua(en).lower(), {}).update(vals)
    return out

# ---- Ukrainian: from the community mod (complete translation) ----
#
# Through tools/ukref.py's cache. Reading the 44 files (51 MB) and hashing their 152k key names used
# to happen on every run of this script; the cache turns that into a 0.2 s read, and rebuilds itself
# when the reference files change (a fingerprint of names, sizes and mtimes lives in the cache).
UK_FOLDER = os.path.join(UKREF, 'ukrainian', 'UkrainianLocalization', 'scripts', 'mods',
                         'UkrainianLocalization')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ukref
uk = ukref.load_by_key(UK_FOLDER)

# ---- collect: key -> {lang: text} ----
data = load_index(INDEX, TERM_KEYS)
for k, v in uk.items():
    if k in data:
        data[k]['uk'] = strip_rich(v)

# What counts as a term is defined once, in tools/term_filter.py, because tools/suggest_terms.py
# looks for the terms this file is missing and has to apply the same rules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from term_filter import is_term, STOP_WORDS  # noqa: E402

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

# ---- Ukrainian the community translation does not cover ----
#
# The game ships no Ukrainian: every uk value here comes from the community translation (Nexus 618),
# matched by loc key. That file is stale (its files date from 2026-08-20) and keyed by its own key
# names, so the update's content and a fistful of older terms have no uk at all.
# translations/uk_extra.lua holds the recovered and the hand-written values for them; see
# tools/fill_uk_gaps.py, whose report says which pass produced each one.
UK_EXTRA = {}
_UK_EXTRA_PATH = os.path.join(REPO, 'translations', 'uk_extra.lua')
if os.path.exists(_UK_EXTRA_PATH):
    for _en, _uk in re.findall(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"',
                               io.open(_UK_EXTRA_PATH, encoding='utf-8').read()):
        UK_EXTRA[unescape_lua(_en).lower()] = unescape_lua(_uk)


def with_uk(en, vals):
    """The same values with a Ukrainian value filled in where the community has none.

    Two sources, in order: translations/uk_extra.lua (values recovered for, or written by, this
    project) and the generated table's own entry for the same English word. The second matters for
    the hand-written blocks: "On", "Other", "Confirm" and "Rampage!" are hand rows, so the community
    value attached to the *index* entry never reached them, and they were the last four terms
    without Ukrainian (measured 2026-09-29).
    """
    if vals.get('uk'):
        return vals
    key = unescape_lua(en).lower()
    extra = UK_EXTRA.get(key) or (terms.get(key) or {}).get('uk')
    if not extra:
        return vals
    merged = dict(vals)
    merged['uk'] = extra
    return merged


_filled = 0
for _key, _langs in terms.items():
    if 'uk' not in _langs and _key in UK_EXTRA:
        _langs['uk'] = UK_EXTRA[_key]
        _filled += 1
print('uk: %d term(s) took their Ukrainian from translations/uk_extra.lua' % _filled)

# ---- carry over whatever a previous run produced (see parse_existing) ----
#
# This happens after the hand-verified blocks are defined, because it needs to know which
# source words those blocks own: they are authoritative for their own terms, and carrying them
# in as well is how every one of them ended up in the file twice (the committed glossary had
# two copies of all ten mechanics terms, and each re-run added a copy of every hand-written
# term). The point of the carry-over is the values the current exports no longer have, e.g.
# Ukrainian, which the game never shipped.

# ---- hand verified core mechanics (no game loc key exists for these) ----
#
# Values are the game's own wording, read out of the localization strings bundle (the
# localization-search index, game-data/index/localization.sqlite): exact strings where the game has
# one, and for "Unknown" the game's UNKNOWN row with the capitalization normalised, because the game
# prints that one in a HUD placeholder in all caps ("UNBEKANNT") which reads wrong as a label.
#
# The rows for Ability, Aura, Blitz, Keystone and Stimm Supply are still listed but are skipped by the
# shadow check at the emission site: a collection round has since resolved the keys that carry them
# (loc_glossary_term_class_ability, loc_glossary_term_aura, loc_tactical_overlay_build_blitz,
# loc_glossary_talent_keystone, loc_talent_broker_ability_stimm_field), and the export - which has
# all 12 languages for each - is authoritative for its own strings.
HAND = [
    ("Ability",  {"zh-cn": "能力", "zh-tw": "技能", "ja": "アビリティ", "ko": "능력", "ru": "Способность", "de": "Fähigkeit", "fr": "Capacité", "es": "Habilidad", "it": "Abilità", "pl": "Zdolność", "pt-br": "Habilidade"}),
    ("Aura",     {"zh-cn": "光环", "zh-tw": "光環", "ja": "オーラ", "ko": "오라", "ru": "Аура", "de": "Aura", "fr": "Aura", "es": "Aura", "it": "Aura", "pl": "Aura", "pt-br": "Aura"}),
    ("Blitz",    {"zh-cn": "闪击", "zh-tw": "閃擊", "ja": "ブリッツ", "ko": "대공세", "ru": "Блиц", "de": "Blitz", "fr": "Blitz", "es": "Bombardeo", "it": "Incursione", "pl": "Szybki Atak", "pt-br": "Bombardeio"}),
    ("Keystone", {"zh-cn": "楔石", "zh-tw": "鑰石", "ja": "キーストーン", "ko": "키스톤", "ru": "Ключевой талант", "de": "Schlüsselstein", "fr": "Clé de voûte", "es": "Piedra angular", "it": "Chiave di volta", "pl": "Filar", "pt-br": "Pedra fundamental"}),
    ("Melee",    {"zh-cn": "近战", "zh-tw": "近戰", "ja": "近接", "ko": "근접", "ru": "Ближний бой", "de": "Nahkampf", "fr": "Mêlée", "es": "Cuerpo a cuerpo", "it": "Corpo a corpo", "pl": "Melee", "pt-br": "Corpo a corpo", "uk": "Ближній бій"}),
    ("Ranged",   {"zh-cn": "远程", "zh-tw": "遠程武器", "ja": "遠隔", "ko": "원거리", "ru": "Дальний бой", "de": "Fernkampf", "fr": "À distance", "es": "A distancia", "it": "A distanza", "pl": "Dystansowe", "pt-br": "Longo alcance"}),
    ("None",     {"zh-cn": "无", "zh-tw": "無", "ja": "なし", "ko": "없음", "ru": "Нет", "de": "Keine", "fr": "Aucun(e)", "es": "Ninguna", "it": "Nessuna", "pl": "Brak", "pt-br": "Nenhum"}),
    ("Unknown",  {"zh-cn": "未知", "zh-tw": "未知", "ja": "不明", "ko": "알 수 없음", "ru": "Неизвестно", "de": "Unbekannt", "fr": "Inconnu", "es": "Desconocido", "it": "Sconosciuto", "pl": "Nieznany", "pt-br": "Desconhecido"}),
    # community names for the same classes (the game's own wording is Arbitrator /
    # Skitarius, but mods often write Arbites / Skitarii) - the values are that wording,
    # which the game itself also uses in strings like "Arbites Class"
    ("Arbites",  {"zh-cn": "法务官", "zh-tw": "法務官", "ja": "裁定者", "ko": "조정관", "ru": "Арбитратор", "de": "Arbitrator", "fr": "Arbitrator", "es": "Arbitrador", "it": "Arbitrator", "pl": "Arbitrator", "pt-br": "Árbitro", "uk": "Арбітр"}),
    ("Skitarii", {"zh-cn": "护教军", "zh-tw": "護教軍", "ja": "スキタリ", "ko": "스키타리", "ru": "Скитарий", "de": "Skitarii", "fr": "Skitarii", "es": "Skitarii", "it": "Gli Skitarii", "pl": "Skitarii", "pt-br": "Skitarii", "uk": "Скітарій"}),
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
    # Terms every installed mod uses and the game localises, found by tools/suggest_terms.py
    # (2026-09-30): it compares the English strings the mods ship with the game's own short
    # strings and reports the ones this glossary was missing. Each row carries the wording of the
    # index row that is localised most widely, and the block is shadowed automatically once a key
    # resolving to the same English enters translations/term_keys.lua.
    ("Ranged Weapon", {"zh-cn": "远程武器", "zh-tw": "遠端武器", "ja": "遠隔武器", "ko": "원거리 무기", "ru": "Дистанционное оружие", "de": "Fernkampfwaffe", "fr": "Arme à distance", "es": "Arma a distancia", "it": "Arma a distanza", "pl": "Broń dystansowa", "pt-br": "Arma de longo alcance"}),
    ("Melee Attack", {"zh-cn": "近战攻击", "zh-tw": "近戰攻擊", "ja": "近接攻撃", "ko": "근접 공격", "ru": "Атака в ближнем бою", "de": "Nahkampfangriff", "fr": "Attaque de mêlée", "es": "Ataque cuerpo a cuerpo", "it": "Attacco corpo a corpo", "pl": "Atak w zwarciu", "pt-br": "Ataque corpo a corpo"}),
    ("Melee Weapon", {"zh-cn": "近战武器", "zh-tw": "近戰武器", "ja": "近接武器", "ko": "근접 무기", "ru": "Оружие ближнего боя", "de": "Nahkampfwaffe", "fr": "Arme de mêlée", "es": "Arma cuerpo a cuerpo", "it": "Arma corpo a corpo", "pl": "Broń biała", "pt-br": "Arma corpo a corpo"}),
    ("Melee Attacks", {"zh-cn": "近战攻击", "zh-tw": "近戰攻擊", "ja": "近接攻撃", "ko": "근접 공격", "ru": "Атаки в ближнего бою", "de": "Nahkampfangriffe", "fr": "Attaques de mêlée", "es": "Ataques cuerpo a cuerpo", "it": "Attacchi corpo a corpo", "pl": "Ataki w zwarciu", "pt-br": "Ataques corpo a corpo"}),
    ("Ranged Attacks", {"zh-cn": "远程攻击", "zh-tw": "遠程攻擊", "ja": "遠隔攻撃", "ko": "원거리 공격", "ru": "Атаки в дальнем бою", "de": "Fernkampfangriffe", "fr": "Attaques à distance", "es": "Ataques a distancia", "it": "Attacchi a distanza", "pl": "Ataki dystansowe", "pt-br": "Ataques de longo alcance"}),
    ("Damage Reduction", {"zh-cn": "伤害降低", "zh-tw": "傷害減少", "ja": "ダメージ軽減", "ko": "대미지 감소", "ru": "Снижение урона", "de": "Schadensreduktion", "fr": "Réduction des dégâts", "es": "Reducción de daño", "it": "Riduzione dei danni", "pl": "Zmniejszenie obrażeń", "pt-br": "Redução de dano"}),
    ("Force Greatsword", {"zh-cn": "力场大剑", "zh-tw": "力場巨劍", "ja": "フォース・グレートソード", "ko": "포스 그레이트소드", "ru": "Длинный психосиловой меч", "de": "Psigroßschwert", "fr": "Épée de force à deux mains", "es": "Mandoble de fuerza", "it": "Spadone psichico", "pl": "Duży miecz psioniczny", "pt-br": "Espadão de força"}),
    ("Ammo Reserve", {"zh-cn": "弹药储备", "zh-tw": "儲備彈藥", "ja": "予備弾薬", "ko": "탄약 보유", "ru": "Резерв боеприпасов", "de": "Reservemunition", "fr": "Réserve de munitions", "es": "Reserva de munición", "it": "Riserva di munizioni", "pl": "Rezerwa amunicji", "pt-br": "Reserva de munição"}),
    ("Melee Damage", {"zh-cn": "近战伤害", "zh-tw": "近戰傷害", "ja": "近接ダメージ", "ko": "근접 대미지", "ru": "Урон в ближнем бою", "de": "Nahkampfschaden", "fr": "Dégâts de mêlée", "es": "Daño cuerpo a cuerpo", "it": "Danni corpo a corpo", "pl": "Obrażenia w zwarciu", "pt-br": "Dano corpo a corpo"}),
    ("Movement Speed", {"zh-cn": "移动速度", "zh-tw": "移動速度", "ja": "移動速度", "ko": "이동 속도", "ru": "Скорость передвижения", "de": "Bewegungsgeschwindigkeit", "fr": "Vitesse de déplacement", "es": "Velocidad de movimiento", "it": "Velocità di movimento", "pl": "Prędkość ruchu", "pt-br": "Velocidade de movimento"}),
    ("Ranged Damage", {"zh-cn": "远程伤害", "zh-tw": "遠程傷害", "ja": "遠隔ダメージ", "ko": "원거리 대미지", "ru": "Урон в дальнем бою", "de": "Fernkampfschaden", "fr": "Dégâts à distance", "es": "Daño a distancia", "it": "Danni a distanza", "pl": "Obrażenia dystansowe", "pt-br": "Dano de longo alcance"}),
    ("Ranged Kills", {"zh-cn": "远程击杀", "zh-tw": "遠程擊殺", "ja": "遠隔キル数", "ko": "원거리 처치", "ru": "Убийства в дальнем бою", "de": "Fernkampf-Tötungen", "fr": "Éliminations à distance", "es": "Bajas a distancia", "it": "Uccisioni a distanza", "pl": "Zabójstwa dystansowe", "pt-br": "Abate de longo alcance"}),
    ("Brunt's Armoury", {"zh-cn": "布伦特的军备库", "zh-tw": "布倫特的軍械庫", "ja": "ブラントの武器庫", "ko": "브런트의 무기고", "ru": "Арсенал Бранта", "de": "Brunts Waffenkammer", "fr": "Armurerie de Brunt", "es": "Armería de Brunt", "it": "Armeria di Brunt", "pl": "Zbrojownia Brunta", "pt-br": "Arsenal de Brunt"}),
    ("Critical Chance", {"zh-cn": "暴击几率", "zh-tw": "暴擊幾率", "ja": "クリティカルチャンス", "ko": "치명타 확률", "ru": "Вероятность крит. удара", "de": "Kritische Trefferchance", "fr": "Taux de coup critique", "es": "Probabilidad de crítico", "it": "Probabilità di critico", "pl": "Szansa na trafienie krytyczne", "pt-br": "Chance de crítico"}),
    ("Fire Grenade", {"zh-cn": "火焰手雷", "zh-tw": "火焰手雷", "ja": "グレネード発射", "ko": "화염 수류탄", "ru": "Бросок гранаты", "de": "Feuergranate", "fr": "Grenade incendiaire", "es": "Granada incendiaria", "it": "Granata infuocata", "pl": "Granat Ogniowy", "pt-br": "Granada de fogo"}),
    ("Havoc Assignment", {"zh-cn": "浩劫任务", "zh-tw": "浩劫任務", "ja": "ハヴォック任務", "ko": "파괴 임무", "ru": "Задание верной смерти", "de": "Verwüstungsauftrag", "fr": "Mission de dévastation", "es": "Encargo de pandemonio", "it": "Incarico Scompiglio", "pl": "Zadanie spustoszenia", "pt-br": "Tarefa de Devastação"}),
    ("Ranged Weapons", {"zh-cn": "远程武器", "zh-tw": "遠端武器", "ja": "遠隔武器", "ko": "원거리 무기", "ru": "Дистанционное оружие", "de": "Fernkampfwaffen", "fr": "Armes à distance", "es": "Armas a distancia", "it": "Armi a distanza", "pl": "Broń dystansowa", "pt-br": "Armas de longo alcance"}),
    ("Stagger Enemies", {"zh-cn": "踉跄敌人", "zh-tw": "使敵人暈眩", "ja": "敵をよろめかせる", "ko": "적 비틀거리게 하기", "ru": "Ошеломить врагов", "de": "Überwältige Gegner", "fr": "Faites vaciller des ennemis.", "es": "Haz tambalear a los enemigos", "it": "Fai barcollare i nemici", "pl": "Oszołom wrogów", "pt-br": "Desequilibrar inimigos"}),
    ("Suppress Enemies", {"zh-cn": "压制敌人", "zh-tw": "壓制敵人", "ja": "敵を制圧する", "ko": "적 제압하기", "ru": "Подавите врагов", "de": "Verdränge die Gegner", "fr": "Infligez Suppression aux ennemis.", "es": "Reprime a los enemigos", "it": "Sopprimi i nemici", "pl": "Tłumienie wrogów", "pt-br": "Suprima os Inimigos"}),
    ("Toughness Damage", {"zh-cn": "韧性伤害", "zh-tw": "韌性傷害", "ja": "タフネスダメージ", "ko": "강인함 대미지", "ru": "Урон стойкости", "de": "Zähigkeitsschaden", "fr": "Dégâts de robustesse", "es": "Daño a la dureza", "it": "Danni alla Robustezza", "pl": "Obrażenia wytrzymałości", "pt-br": "Dano de Resistência"}),
    ("Aim Down Sights", {"zh-cn": "瞄准视角", "zh-tw": "機瞄", "ja": "照準を合わせる", "ko": "정조준", "ru": "Прицеливание", "de": "Visier", "fr": "Viseur", "es": "Mira", "it": "Mirino", "pl": "Celowanie", "pt-br": "Mira"}),
    ("Ammo Crate", {"zh-cn": "弹药箱", "zh-tw": "彈藥箱", "ja": "弾薬クレート", "ko": "탄약 상자", "ru": "Контейнер с боеприпасами", "de": "Munitionskiste", "fr": "Caisse de munitions", "es": "Caja de munición", "it": "Cassa di munizioni", "pl": "Skrzynia z amunicją", "pt-br": "Caixote de Munição"}),
    ("Ascension Riser", {"zh-cn": "升降机", "zh-tw": "升降機", "ja": "アセンションライザー", "ko": "어센션 라이저", "ru": "Подъемная платформа", "de": "Aufzug", "fr": "Élévateur à ascension", "es": "Elevador de ascenso", "it": "Elevatore ascendente", "pl": "Unośnik", "pt-br": "Ascensor"}),
    ("Attack Speed", {"zh-cn": "攻击速度", "zh-tw": "攻擊速度", "ja": "攻撃速度", "ko": "공격 속도", "ru": "Скорость атаки", "de": "Angriffsgeschwindigkeit", "fr": "Vitesse d'attaque", "es": "Velocidad de ataque", "it": "Velocità d'attacco", "pl": "Prędkość ataku", "pt-br": "Velocidade de Ataque"}),
    ("Breaching Charge", {"zh-cn": "爆破炸药", "zh-tw": "爆破炸藥", "ja": "爆薬設置", "ko": "파괴 충전", "ru": "Пробивной заряд", "de": "Sprengladung", "fr": "Charge de brèche", "es": "Carga de irrupción", "it": "Carica di sfondamento", "pl": "Ładunek do wyłomów", "pt-br": "Carga de abertura"}),
    ("Celerity Stimm", {"zh-cn": "敏捷兴奋剂", "zh-tw": "敏捷興奮劑", "ja": "迅速化刺激剤", "ko": "민첩성 자극제", "ru": "Стимулятор рефлексов", "de": "Aufputschmittel für Geschwindigkeit", "fr": "Stimulant de célérité", "es": "Estimulante de celeridad", "it": "Stimolante per la speditezza", "pl": "Stymulator pośpiechu", "pt-br": "Estimulante de Velocidade"}),
    ("Charge Up", {"zh-cn": "充能", "zh-tw": "充能", "ja": "チャージ", "ko": "충전", "ru": "Зарядить", "de": "Aufladen", "fr": "Chargement", "es": "Carga aumentada", "it": "Ricarica", "pl": "Doładowanie", "pt-br": "Carregar"}),
    ("Chem Toxin", {"zh-cn": "化学毒素", "zh-tw": "化學毒素", "ja": "ケム毒", "ko": "화학 독소", "ru": "Химтоксин", "de": "Chem-Toxin", "fr": "Toxine chimique", "es": "Toxina química", "it": "Tossina Chimica", "pl": "Toksyna chemiczna", "pt-br": "Quimiotoxina"}),
    ("Combat Stimm", {"zh-cn": "作战兴奋剂", "zh-tw": "作戰興奮劑", "ja": "戦闘用刺激剤", "ko": "전투력 자극제", "ru": "Стимулятор боевых навыков", "de": "Aufputschmittel für den Kampf", "fr": "Stimulant de combat", "es": "Estimulante de combate", "it": "Stimolante da combattimento", "pl": "Stymulator bojowy", "pt-br": "Estimulante de Combate"}),
    ("Commodore's Vestures", {"zh-cn": "准将的服装", "zh-tw": "准將服裝店", "ja": "准将服", "ko": "준장의 수확물", "ru": "Oдеяние от Командора", "de": "Gewänder des Kommodore", "fr": "Vêtements du Commodore", "es": "Vestiduras de la comodoro", "it": "Vesti del commodoro", "pl": "Szaty Komodor", "pt-br": "Vestes do Comodoro"}),
    ("Concentration Stimm", {"zh-cn": "专注兴奋剂", "zh-tw": "專注興奮劑", "ja": "集中用刺激剤", "ko": "집중력 자극제", "ru": "Стимулятор концентрации", "de": "Aufputschmittel für die Konzentration", "fr": "Stimulant de concentration", "es": "Estimulante de concentración", "it": "Stimolante per la concentrazione", "pl": "Stymulator koncentracji", "pt-br": "Estimulante de Concentração"}),
    ("Damage Taken", {"zh-cn": "所受伤害", "zh-tw": "承受傷害", "ja": "受けたダメージ", "ko": "받은 대미지", "ru": "Получено урона", "de": "Erlittener Schaden", "fr": "Dégâts subis", "es": "Daño recibido", "it": "Danni subiti", "pl": "Odniesione obrażenia", "pt-br": "Dano sofrido"}),
    ("Devil's Claw", {"zh-cn": "恶魔之爪", "zh-tw": "惡魔之爪", "ja": "悪魔の爪", "ko": "악마의 발톱", "ru": "Дьявольский коготь", "de": "Teufelsklaue", "fr": "Griffe du diable", "es": "Garra del Diablo", "it": "Artiglio del diavolo", "pl": "Diabelski Pazur", "pt-br": "Garra do Demônio"}),
    ("Diligent Patrol", {"zh-cn": "勤勉巡查", "zh-tw": "勤於巡邏", "ja": "勤勉なパトロール", "ko": "성실한 정찰", "ru": "Бдительный патруль", "de": "Sorgfältige Patrouille", "fr": "Patrouille diligente", "es": "Patrulla diligente", "it": "Pattuglia diligente", "pl": "Pilny patrol", "pt-br": "Patrulha diligente"}),
    ("Elite Kill", {"zh-cn": "精英击杀", "zh-tw": "精英擊殺", "ja": "上位者撃破", "ko": "엘리트 처치", "ru": "Убийство элитн.", "de": "Elite-Tötung", "fr": "Élimination d'élite", "es": "Baja de élite", "it": "Uccisione élite", "pl": "Zabójstwo elity", "pt-br": "Morte de Elite"}),
    ("Emperor's Will", {"zh-cn": "帝皇之意", "zh-tw": "帝皇意志", "ja": "皇帝の意思", "ko": "황제의 의지", "ru": "Воля Императора", "de": "Wille des Imperators", "fr": "Volonté de l'Empereur", "es": "Voluntad del emperador", "it": "La volontà dell'Imperatore", "pl": "Wola Imperatora", "pt-br": "Vontade do Imperador"}),
    ("Enemy Types", {"zh-cn": "敌人类型", "zh-tw": "敵人類型", "ja": "敵のタイプ", "ko": "적 유형", "ru": "Типы врагов", "de": "Feindarten", "fr": "Types d'ennemis", "es": "Tipos de enemigos", "it": "Tipi di nemici", "pl": "Typy wrogów", "pt-br": "Tipos de inimigo"}),
    ("For the Emperor", {"zh-cn": "为了帝皇", "zh-tw": "為了帝皇", "ja": "皇帝の名の下に", "ko": "황제를 위하여", "ru": "За Императора", "de": "Für den Imperator", "fr": "Pour l'Empereur", "es": "Por el Emperador", "it": "Per l'Imperatore", "pl": "Za Imperatora", "pt-br": "Pelo Imperador"}),
    ("Force Swords", {"zh-cn": "力场剑", "zh-tw": "力場劍", "ja": "フォースソード", "ko": "포스 검", "ru": "Психосиловые мечи", "de": "Psischwerter", "fr": "Épées de force", "es": "Espadas de fuerza", "it": "Spade psichiche", "pl": "Miecze psioniczne", "pt-br": "Espadas de força"}),
    ("Forge's Bellow", {"zh-cn": "熔炉怒吼", "zh-tw": "熔爐怒吼", "ja": "鍛造場の息吹", "ko": "모루의 함성", "ru": "Рев кузни", "de": "Schrei der Schmiede", "fr": "Beuglement de forge", "es": "Bramido de la forja", "it": "Ruggito della Forgia", "pl": "Ryk Kuźni", "pt-br": "Brado da Forja"}),
    ("Havoc Rewards", {"zh-cn": "浩劫奖励", "zh-tw": "浩劫獎勵", "ja": "ハヴォック報酬", "ko": "파괴 보상", "ru": "Награды верной смерти", "de": "Verwüstungsbelohnungen", "fr": "Récompenses de dévastation", "es": "Recompensas de pandemonio", "it": "Ricompense Scompiglio", "pl": "Nagrody spustoszenia", "pt-br": "Recompensas de Devastação"}),
    ("Kill Enemies", {"zh-cn": "击杀敌人", "zh-tw": "擊殺敵人", "ja": "敵を倒せ", "ko": "적 처치하기", "ru": "Убейте врагов", "de": "Töte Feinde", "fr": "Tuez les ennemis.", "es": "Mata a enemigos", "it": "Uccidi i nemici", "pl": "Zabij wrogów", "pt-br": "Matar inimigos"}),
    ("Lieutenant Masozi", {"zh-cn": "马佐齐副官", "zh-tw": "馬佐齊中尉", "ja": "マソジ副官", "ko": "마소지 중위", "ru": "Лейтенант Масози", "es": "Teniente Masozi", "it": "Tenente Masozi", "pl": "porucznik Masozi", "pt-br": "Tenente Masozi"}),
    ("Martyr's Skull", {"zh-cn": "殉道者头骨", "zh-tw": "殉道者之顱", "ja": "殉教者の髑髏", "ko": "순교자의 두개골", "ru": "Череп мученика", "de": "Schädel des Märtyrers", "fr": "Crâne du martyr", "es": "Cráneo de mártir", "it": "Teschio del Martire", "pl": "Czaszka męczennika", "pt-br": "Caveira do Mártir"}),
    ("Med Stimm", {"zh-cn": "医疗兴奋剂", "zh-tw": "醫療興奮劑", "ja": "医薬品", "ko": "약물", "ru": "Медицинский стимулятор", "de": "Med-Aufputschmittel", "fr": "Stimulant médical", "es": "Estimulante medicinal", "it": "Stimolante medicae", "pl": "Stymulator medyczny", "pt-br": "Med-estimulante"}),
    ("Medicae Station", {"zh-cn": "医疗站", "zh-tw": "醫療站", "ja": "メディケアステーション", "ko": "치료소", "ru": "Медстанция", "de": "Medicae-Station", "fr": "Station médicale", "es": "Estación médica", "it": "Stazione medicae", "pl": "Medstacja", "pt-br": "Estação de Remédios"}),
    ("Melee Attack Speed", {"zh-cn": "近战攻击速度", "zh-tw": "近戰攻擊速度", "ja": "近接攻撃速度", "ko": "근접 공격 속도", "ru": "Скорость атаки в ближнем бою", "de": "Angriffsgeschwindigkeit im Nahkampf", "fr": "Vitesse d'attaque de mêlée", "es": "Velocidad de ataque cuerpo a cuerpo", "it": "Velocità d'attacco corpo a corpo", "pl": "Prędkość ataku w zwarciu", "pt-br": "Velocidade de ataque corpo a corpo"}),
    ("Melee Hits", {"zh-cn": "近战命中", "zh-tw": "近戰命中", "ja": "近接ヒット", "ko": "근접 공격 명중", "ru": "Удары в ближнем бою", "de": "Nahkampftreffer", "fr": "Coups en mêlée", "es": "Golpes cuerpo a cuerpo", "it": "Colpi corpo a corpo", "pl": "Trafienia w zwarciu", "pt-br": "Acertos corpo a corpo"}),
    ("Melee Kills", {"zh-cn": "近战击杀", "zh-tw": "近戰擊殺", "ja": "近接キル数", "ko": "근접 처치", "ru": "Убийства в ближнем бою", "de": "Nahkampftötungen", "fr": "Éliminations en mêlée", "es": "Bajas cuerpo a cuerpo", "it": "Uccisioni corpo a corpo", "pl": "Zabójstwa w zwarciu", "pt-br": "Abates corpo a corpo"}),
    ("Nearby Enemies", {"zh-cn": "附近敌人", "zh-tw": "附近敵人", "ja": "近くの敵", "ko": "근처 적", "ru": "Ближайшие враги", "de": "Nahe Feinde", "fr": "Ennemis à proximité", "es": "Enemigos cercanos", "it": "Nemici vicini", "pl": "Pobliscy wrogowie", "pt-br": "Inimigos próximos"}),
    ("Noospheric Command", {"zh-cn": "星语指令", "zh-tw": "心智網指令", "ja": "ノウスフィアコマンド", "ko": "누스피어 명령", "ru": "Ноосферная команда", "de": "Noosphärischer Befehl", "fr": "Commandement noosphérique", "es": "Orden noosférica", "it": "Comando Noosferico", "pl": "Noosferyczne Dowodzenie", "pt-br": "Comando Noosférico"}),
    ("Open the Gate", {"zh-cn": "打开大门", "zh-tw": "開啟大門", "ja": "門を開ける", "ko": "문 열기", "ru": "Откройте ворота", "de": "Öffnet das Tor", "fr": "Ouvrez la porte.", "es": "Abre la puerta", "it": "Apri il cancello", "pl": "Otwórzcie bramę", "pt-br": "Abra o portão"}),
    ("Other Talents", {"zh-cn": "其他天赋", "zh-tw": "其他天賦", "ja": "その他のタレント", "ko": "기타 재능", "ru": "Другие таланты", "de": "Sonstige Talente", "fr": "Autres talents", "es": "Otros talentos", "it": "Altri talenti", "pl": "Pozostałe talenty", "pt-br": "Outros talentos"}),
    ("Plasma Guns", {"zh-cn": "等离子枪", "zh-tw": "等離子槍", "ja": "プラズマガン", "ko": "플라즈마 건", "ru": "Плазмомёты", "de": "Plasmagewehre", "fr": "Fusils à plasma", "es": "Cañones de plasma", "it": "Fucili al plasma", "pl": "Bronie plazmowe", "pt-br": "Armas de plasma"}),
    ("Portrait Frame", {"zh-cn": "肖像框", "zh-tw": "肖像框", "ja": "ポートレートフレーム", "ko": "초상화 프레임", "ru": "Портретная рамка", "de": "Porträtrahmen", "fr": "Cadre de portrait", "es": "Marco de retrato", "it": "Cornice ritratto", "pl": "Ramka portretowa", "pt-br": "Moldura de Retrato"}),
    ("Power Cell", {"zh-cn": "能量电池", "zh-tw": "能量電池", "ja": "パワーセル", "ko": "배터리", "ru": "Силовой элемент", "de": "Energiezelle", "fr": "Batterie", "es": "Célula de energía", "it": "Batteria", "pl": "Ogniwo zasilania", "pt-br": "Célula de energia"}),
    ("Power Switch", {"zh-cn": "能源开关", "zh-tw": "電力開關", "ja": "パワースイッチ", "ko": "전력 스위치", "ru": "Переключатель", "de": "Energieschalter", "fr": "Levier d'alimentation", "es": "Interruptor de energía", "it": "Interruttore di corrente", "pl": "Przełącznik zasilania", "pt-br": "Interruptor de energia"}),
    ("Pull the Lever", {"zh-cn": "拉下拉杆", "zh-tw": "拉動操縱桿", "ja": "レバーを引く", "ko": "레버 당기기", "ru": "Потяните рычаг", "de": "Zieht den Hebel", "fr": "Actionner le levier", "es": "Tirad de la palanca", "it": "Tira la leva", "pl": "Pociągnijcie za dźwignię", "pt-br": "Puxe a alavanca"}),
    ("Ranged Specialist", {"zh-cn": "远程专家", "zh-tw": "遠程專家", "ja": "遠距離のスペシャリスト", "ko": "원거리 전문가", "ru": "Специалист дальнего боя", "de": "Fernkampfspezialist", "fr": "Spécialiste à distance", "es": "Especialista a distancia", "it": "Specialista a distanza", "pl": "Specjalista dystansowy", "pt-br": "Especialista de longo alcance"}),
    ("Regen Rate", {"zh-cn": "恢复速度", "zh-tw": "恢復速率", "ja": "回復率", "ko": "재생 속도", "ru": "Скорость реген.", "de": "Rate der Regen", "fr": "Taux de régén", "es": "Tasa de Regen", "it": "Tasso Rigen.", "pl": "Tempo Regen", "pt-br": "Taxa de Regen"}),
    ("Relay Station", {"zh-cn": "中继站", "zh-tw": "中繼站", "ja": "中継局", "ko": "중계기 스테이션", "ru": "Ретранслятор", "de": "Relaisstation", "fr": "Station relais", "es": "Estación de transmisión", "it": "Stazione di trasmissione", "pl": "Stacja przekazywania", "pt-br": "Estação Retransmissora"}),
    ("Savvy Operator", {"zh-cn": "老练干员", "zh-tw": "精明的幹員", "ja": "手練れのオペレーター", "ko": "노련한 운영자", "ru": "Бывалый боец", "de": "Gerissener Operator", "fr": "Opérateur spécialiste", "es": "Operador espabilado", "it": "Operatore scaltro", "pl": "Sprytny operator", "pt-br": "Operador Sagaz"}),
    ("Skull Weight", {"zh-cn": "配重头骨", "zh-tw": "顱骨重量", "ja": "髑髏の重り", "ko": "두개골 추", "ru": "Вес черепа", "de": "Schädelgewicht", "fr": "Poids en forme de crâne", "es": "Cráneo pesado", "it": "Peso a forma di teschio", "pl": "Ciężka czaszka", "pt-br": "Peso de crânio"}),
    ("Slab Shield", {"zh-cn": "板砖大盾", "zh-tw": "厚板盾", "ja": "デカブツシールド", "ko": "슬랩 실드", "ru": "Щит Верзилы", "de": "Klotzschild", "fr": "Bouclier de Colosse", "es": "Escudo de moles", "it": "Scudo spesso", "pl": "Tarcza płytowa", "pt-br": "Escudo Ogro"}),
    ("Smoke Screen", {"zh-cn": "烟幕", "zh-tw": "煙幕", "ja": "煙幕", "ko": "연막", "ru": "Дымовая завеса", "de": "Rauchwand", "fr": "Écran de fumée", "es": "Pantalla de humo", "it": "Cortina fumogena", "pl": "Zasłona dymna", "pt-br": "Cortina de fumaça"}),
    ("Special Condition", {"zh-cn": "特殊状况", "zh-tw": "特殊環境", "ja": "特殊条件", "ko": "특별 조건", "ru": "Особое обстоятельство", "de": "Spezielle Kondition", "fr": "Condition spéciale", "es": "Condición especial", "it": "Condizione speciale", "pl": "Stan specjalny", "pt-br": "Condição especial"}),
    ("Stamina Regeneration", {"zh-cn": "体力恢复", "zh-tw": "體力恢復", "ja": "スタミナ回復", "ko": "스태미너 재생", "ru": "Восстановление выносливости", "de": "Ausdauerregeneration", "fr": "Régénération d'endurance", "es": "Regeneración de resistencia", "it": "Rigenerazione di Resistenza", "pl": "Regeneracja kondycji", "pt-br": "Regeneração de vigor"}),
    ("Stimm Component", {"zh-cn": "兴奋剂原料", "zh-tw": "興奮劑原料", "ja": "薬剤成分", "ko": "자극제 약물 재료", "ru": "Компонент стимулятора", "de": "Aufputschmittel-Komponente", "fr": "Composant de stimulant", "es": "Componente de estimulante", "it": "Componente stimolante", "pl": "Komponent Stymulatora", "pt-br": "Componente de estimulante"}),
    ("Stub Revolver", {"zh-cn": "短柄左轮枪", "zh-tw": "短管左輪槍", "ja": "スタブリボルバー", "ko": "스터브 리볼버", "ru": "Стаб-револьвер", "de": "Stub-Revolver", "fr": "Revolver à canon court", "es": "Revólver semiautomático", "it": "Revolver a canna corta", "pl": "Krótki rewolwer", "pt-br": "Revólver Pesado"}),
    ("Tainted Communications Device", {"zh-cn": "腐化通讯装置", "zh-tw": "通訊干擾裝置", "ja": "不浄の通信装置", "ko": "오염된 통신 장치", "ru": "Оскверненное средство связи", "de": "Verdorbenes Kommunikationsgerät", "fr": "Appareil de communication corrompu", "es": "Dispositivo de comunicación corrupto", "it": "Dispositivo di comunicazione corrotto", "pl": "Skażone urządzenie komunikacyjne", "pt-br": "Dispositivos de comunicação adulterados"}),
    ("Tainted Skull", {"zh-cn": "腐化颅骨", "zh-tw": "腐敗顱骨", "ja": "汚れた頭骨", "ko": "타락한 두개골", "ru": "Оскверненный череп", "de": "Verdorbener Schädel", "fr": "Crâne corrompu", "es": "Cráneo corrupto", "it": "Teschi corrotto", "pl": "Skażona czaszka", "pt-br": "Crânio maculado"}),
    ("Taking Damage", {"zh-cn": "受到伤害", "zh-tw": "承受傷害", "ja": "被ダメージ中", "ko": "대미지 받음", "ru": "Получение урона", "de": "Nimmt Schaden", "fr": "Subit des dégâts", "es": "Recibiendo daño", "it": "Subire danni", "pl": "Odnoszenie obrażeń", "pt-br": "Sofrendo dano"}),
    ("Tancred Bastion", {"zh-cn": "唐克雷德堡垒", "zh-tw": "坦克雷德堡壘", "ja": "タンクレード・バスチョン", "ko": "탄크레드 감옥선", "ru": "Бастион Танкред", "de": "Tancred-Bastion", "fr": "Bastion de Tancred", "es": "Bastión del Buen Consejo", "it": "Bastione di Tancred", "pl": "Bastion Tancred", "pt-br": "Bastião de Tancred"}),
    ("Targeted Toxin", {"zh-cn": "精准毒素", "zh-tw": "精準投毒", "ja": "標的毒化", "ko": "표적 독", "ru": "Нацеленный токсин", "de": "Gezieltes Toxin", "fr": "Toxine ciblée", "es": "Toxinas dirigidas", "it": "Tossina bersagliata", "pl": "Ukierunkowana Toksyna", "pt-br": "Toxina Direcionada"}),
    ("Theatre of Castigation", {"zh-cn": "惩戒剧场", "zh-tw": "責難劇場", "ja": "懲戒の劇場", "ko": "견책의 극장", "ru": "Театр Бичевания", "de": "Das Theater der Züchtigung", "fr": "Le théâtre de la réprimande", "es": "El teatro del castigo", "it": "Il Teatro del castigo", "pl": "Teatr Karcenia", "pt-br": "Teatro do Castigo"}),
    ("Theatre of Humility", {"zh-cn": "谦卑剧场", "zh-tw": "謙卑劇場", "ja": "謙虚の劇場", "ko": "겸손의 극장", "ru": "Театр Смирения", "de": "Das Theater der Demut", "fr": "Le théâtre de l'humilité", "es": "El teatro de la humildad", "it": "Il Teatro dell'umiltà", "pl": "Teatr Pokory", "pt-br": "Teatro da Humildade"}),
    ("Tox Flamer", {"zh-cn": "剧毒火焰兵", "zh-tw": "毒焰噴射者", "ja": "トックス・フレイマー", "ko": "독성 플레이머", "ru": "Токсичный Огневик", "de": "Gift-Flammenwerfer", "fr": "Incendiaire toxique", "es": "Lanzallamas Tóxico", "it": "Sparafiamme tossico", "pl": "Toksypalacz", "pt-br": "Flamejante Tóxico"}),
    ("Trust Level", {"zh-cn": "信任等级", "zh-tw": "信任等級", "ja": "信頼度", "ko": "신뢰 레벨", "ru": "Уровень доверия", "de": "Vertrauenslevel", "fr": "Niveau de confiance", "es": "Nivel de confianza", "it": "Livello di fiducia", "pl": "Poziom zaufania", "pt-br": "Nível de confiança"}),
    ("Vantage Point", {"zh-cn": "有利位置", "zh-tw": "有利地形", "ja": "バンテージ・ポイント", "ko": "저격 지점", "ru": "Точка обзора", "de": "Aussichtspunkt", "fr": "Position avantageuse", "es": "Punto de ventaja", "it": "Punto di vantaggio", "pl": "Punkt widokowy", "pt-br": "Ponto de vantagem"}),
    ("Vent Heat", {"zh-cn": "排出热气", "zh-tw": "排出熱量", "ja": "熱放出", "ko": "열 환기", "ru": "Отводит тепло", "de": "Hitze ablassen", "fr": "Évacuation de chaleur", "es": "Liberar calor", "it": "Dispersione di calore", "pl": "Wentylacja ciepła", "pt-br": "Calor da ventilação"}),
    ("Virulent Strain", {"zh-cn": "强效菌株", "zh-tw": "劇毒菌株", "ja": "悪性菌株", "ko": "치명적인 역병", "ru": "Вирулентный штамм", "de": "Virulenter Strang", "fr": "Souche virulente", "es": "Cepa virulenta", "it": "Ceppo virulento", "pl": "Zjadliwy Szczep", "pt-br": "Cepa Virulenta"}),
    ("Warp Charge", {"zh-cn": "亚空间充能", "zh-tw": "亞空間充能", "ja": "ワープ・チャージ", "ko": "워프 충전", "ru": "Варп-заряд", "de": "Warp-Ladung", "fr": "Recharge de warp", "es": "Carga de disformidad", "it": "Carica Warp", "pl": "Ładunek Osnowy", "pt-br": "Carga de Dobra"}),
    ("Weak Spot", {"zh-cn": "弱点", "zh-tw": "弱點", "ja": "弱点", "ko": "약점", "ru": "Слабое место", "de": "Schwachstelle", "fr": "Point faible", "es": "Punto débil", "it": "Punto debole", "pl": "Słaby punkt", "pt-br": "Ponto fraco"}),
    # Names a weapon-mod option label exposed (no_more_overloads, 2026-09-30): the game has
    # them - the index holds all twelve languages - but the keys carrying them are not in the key
    # list, so no pass ever fetched them. Generic weapon and mechanic names, safe to mask.
    ("Force Staff", {"zh-cn": "力场杖", "zh-tw": "力場法杖", "ja": "フォースの杖", "ko": "포스 지팡이", "ru": "Психосиловой посох", "de": "Psistab", "fr": "Bâton de force", "es": "Báculo de fuerza", "it": "Bastone psichico", "pl": "Laska psioniczna", "pt-br": "Cajado de força"}),
    ("Force Sword", {"zh-cn": "力场剑", "zh-tw": "力場劍", "ja": "フォースソード", "ko": "포스 검", "ru": "Психосиловой меч", "de": "Psischwert", "fr": "Épée de force", "es": "Espada de fuerza", "it": "Spada psichica", "pl": "Miecz psioniczny", "pt-br": "Espada de força"}),
    ("Laspistol", {"zh-cn": "激光手枪", "zh-tw": "鐳射手槍", "ja": "ラスピストル", "ko": "레이저 피스톨", "ru": "Лазпистолет", "de": "Laserpistole", "fr": "Pistolet laser", "es": "Pistola láser", "it": "Pistola laser", "pl": "Pistolet laserowy", "pt-br": "Pistola de laser"}),
    ("Overload", {"zh-cn": "过载", "zh-tw": "超載", "ja": "オーバーロード", "ko": "과부하", "ru": "Перегрузка", "de": "Überladung", "fr": "Surcharge", "es": "Sobrecarga", "it": "Sovraccarico", "pl": "Przeciążenie", "pt-br": "Sobrecarga"}),
    # Names a weapon-mod option label exposed (no_more_overloads, 2026-09-30): the game has
    # them - the index holds all twelve languages - but the keys carrying them are not in the key
    # list, so no pass ever fetched them. Generic weapon and mechanic names, safe to mask.
    # Hive Scum (Broker) combat abilities. The game spells the name with its own exclamation mark,
    # and the mod writes the English that way too ("Rampage!"), so both spellings are listed: the
    # matcher prefers the longer term where it applies.
    #
    # The 12 language values are the game's own shout, read out of the strings bundle ("Rampage!" =
    # 怒火冲天！ / 大暴れだ！ / Буйство! / Randale! / …), so they are the ability's wording and not a
    # translation of it.
    #
    # The bare "Rampage" row stays Chinese only on purpose: the game's own bare "Rampage" is a
    # *different* string - the Nurgle blessing/perk, 狂暴 / 暴走 / Randale / Carnage / … - while a mod
    # that lists abilities writes the ability without its exclamation mark. Giving that row the
    # blessing's ten other spellings would mix the two up, so it keeps the hand decided Chinese.
    ("Rampage!",       {"zh-cn": "怒火冲天！", "zh-tw": "怒火沖天！", "ja": "大暴れだ！", "ko": "날뛰자!", "ru": "Буйство!", "de": "Randale!", "fr": "Carnage !", "es": "¡Estampida!", "it": "Furia!", "pl": "Rzeźnia!", "pt-br": "Fúria!"}),
    ("Rampage",        {"zh-cn": "怒火冲天", "zh-tw": "怒火沖天"}),
    ("Stimm Supply",   {"zh-cn": "兴奋剂补给", "zh-tw": "興奮劑補給"}),

    # ---- game concepts a mod UI names in English, where the collected key list has no string yet ----
    #
    # Every value below is the game's own wording for that concept, read out of the localization
    # strings bundle (extracted with the localization-search workflow: 2.2M strings, all 12
    # languages) rather than translated by hand:
    #
    #   Grimoire      the pickup that corrupts the team while it is carried - the giveaway in any text
    #                 (hud_studio's .mod block, BetterBots' "carry grimoires"): 魔法书 / 法術書 /
    #                 グリモア / 그리모어 / Гримуар / Grimoire / Grimorio / Grymuar / Grimório. The zh-tw
    #                 *barks* say 魔典 and 魔導書; the item itself is 法術書.
    #   Scripture     the other pickup: 圣经 / 聖書 / 성경... the game's own rows are 圣经 / 聖書 /
    #                 聖書 / 경전 / Писания / Schriften / Textes sacrés / Escrituras / Scritture /
    #                 Pisma / Escrituras.
    #   Corruption    the mechanic a grimoire applies: 腐化 / 腐敗 / 腐敗 / 부패 / Скверна / Verderbnis /
    #                 Corruption / Corrupción / Corruzione / Splugawienie / Corrupção.
    #   Coherency     the aura the team keeps: 连携 / 協同 / 周囲 / 단결 / Сплоченность / Kohärenz /
    #                 Syntonie / Coherencia / Sintonia / Spójność / Coerência.
    #   Wounds        the wound pips: 伤口 / 傷口 / 負傷 / 부상 / Ранение / Wunde / Blessure / Herida /
    #                 Ferita / Rana / Ferimento. Deliberately NOT 创伤: the game uses 创伤 for Trauma
    #                 ("Trauma Force Staff" = 创伤力场杖), and the earlier hand value was wrong.
    #   Mourningstar  the hub (loc_hud_presence_hub = "The Mourningstar" = 哀星号): 哀星号 / 哀星號 /
    #                 モーニングスター / 모어닝스타 / Моунингстар, and the proper noun stays as written in
    #                 de/fr/es/it/pl/pt-br - the game prints it with an article inside a sentence
    #                 ("Die Mourningstar"), which is not a drop-in term.
    #   Havoc Rank    the game has no string of this spelling, and the Havoc family has two official
    #                 concepts behind it, neither of which the export carries:
    #                   * "Assignment Rank" = the rank a Havoc assignment gives (任务等级 / 任務級別 /
    #                     任務ランク / 임무 랭크 / Ранг задания / Auftragsrang / Rang de mission /
    #                     Rango de encargo / Rango dell'incarico / Ranga zadania / Ranque de tarefa)
    #                   * "Clearance Level" = the clearance ladder (许可等级 / 許可等級 /
    #                     クリアランスレベル / 허가 레벨 / Уровень допуска / Abschlusslevel /
    #                     Niveau d'autorisation / Nivel de permiso / Livello di autorizzazione /
    #                     Poziom dostępu / Nível de conclusão)
    #                 The label says "Rank", so this row takes the assignment-rank wording with the
    #                 Havoc prefix, spelled the way the game's own compound row does it
    #                 ("Unlocks Havoc Assignment Rank {rank}"): 浩劫任务等级 / 浩劫任務級別 /
    #                 ハヴォック任務ランク / 파괴 임무 랭크 / Ранг задания верной смерти /
    #                 Verwüstung-Auftragsrang / Rang de mission de dévastation /
    #                 Rango de encargo de pandemonio / Rango dell'incarico Scompiglio /
    #                 Ranga zadania spustoszenia / Ranque de tarefa de Devastação. Both plain concepts
    #                 are terms of their own below, so mod text that spells them out also lands right.
    #
    #                 Not rank names: "Havoc Exemplar", "Havoc Vanguard", "Havoc Master" and
    #                 "Havoc Mastery ({tier})" are achievements and titles (the {tier} placeholder is
    #                 the giveaway), so they are deliberately not in the glossary - a rank label must
    #                 not resolve to a title.
    ("Grimoire",       {"zh-cn": "魔法书", "zh-tw": "法術書", "ja": "グリモア", "ko": "그리모어", "ru": "Гримуар", "de": "Grimoire", "fr": "Grimoire", "es": "Grimorio", "it": "Grimorio", "pl": "Grymuar", "pt-br": "Grimório"}),
    ("Scripture",      {"zh-cn": "圣经", "zh-tw": "聖書", "ja": "聖書", "ko": "경전", "ru": "Писания", "de": "Schriften", "fr": "Textes sacrés", "es": "Escrituras", "it": "Scritture", "pl": "Pisma", "pt-br": "Escrituras"}),
    ("Corruption",     {"zh-cn": "腐化", "zh-tw": "腐敗", "ja": "腐敗", "ko": "부패", "ru": "Скверна", "de": "Verderbnis", "fr": "Corruption", "es": "Corrupción", "it": "Corruzione", "pl": "Splugawienie", "pt-br": "Corrupção"}),
    ("Coherency",      {"zh-cn": "连携", "zh-tw": "協同", "ja": "周囲", "ko": "단결", "ru": "Сплоченность", "de": "Kohärenz", "fr": "Syntonie", "es": "Coherencia", "it": "Sintonia", "pl": "Spójność", "pt-br": "Coerência"}),
    ("Wounds",         {"zh-cn": "伤口", "zh-tw": "傷口", "ja": "負傷", "ko": "부상", "ru": "Ранение", "de": "Wunde", "fr": "Blessure", "es": "Herida", "it": "Ferita", "pl": "Rana", "pt-br": "Ferimento"}),
    ("Mourningstar",   {"zh-cn": "哀星号", "zh-tw": "哀星號", "ja": "モーニングスター", "ko": "모어닝스타", "ru": "Моунингстар", "de": "Mourningstar", "fr": "Mourningstar", "es": "Mourningstar", "it": "Mourningstar", "pl": "Mourningstar", "pt-br": "Mourningstar"}),
    ("Havoc Rank",     {"zh-cn": "浩劫任务等级", "zh-tw": "浩劫任務級別", "ja": "ハヴォック任務ランク", "ko": "파괴 임무 랭크", "ru": "Ранг задания верной смерти", "de": "Verwüstung-Auftragsrang", "fr": "Rang de mission de dévastation", "es": "Rango de encargo de pandemonio", "it": "Rango dell'incarico Scompiglio", "pl": "Ranga zadania spustoszenia", "pt-br": "Ranque de tarefa de Devastação"}),
    ("Assignment Rank", {"zh-cn": "任务等级", "zh-tw": "任務級別", "ja": "任務ランク", "ko": "임무 랭크", "ru": "Ранг задания", "de": "Auftragsrang", "fr": "Rang de mission", "es": "Rango de encargo", "it": "Rango dell'incarico", "pl": "Ranga zadania", "pt-br": "Ranque de tarefa"}),
    ("Clearance Level", {"zh-cn": "许可等级", "zh-tw": "許可等級", "ja": "クリアランスレベル", "ko": "허가 레벨", "ru": "Уровень допуска", "de": "Abschlusslevel", "fr": "Niveau d'autorisation", "es": "Nivel de permiso", "it": "Livello di autorizzazione", "pl": "Poziom dostępu", "pt-br": "Nível de conclusão"}),
]

# ---- short names a mod UI writes for a breed ----
#
# The exports only ever carry the game's *full* breed name, because that is the string the game
# localises: "Scab Mauler", "Scab Sniper", "Dreg Tox Bomber". Mod UIs name the breed on its own -
# a highlight option reads "Enable Crusher/Mauler Aggro Glow" or "Sniper Glow Color" - and a short
# name matches nothing, so the word went to the engine: the measured result of that exact string was
# 启用粉碎者/猛击者·激进·光辉 (Crusher was protected, Mauler was not), and "Captain / Twins" came
# back as 队长 / 双生.
#
# So each row below is the breed word on its own, and its value comes from the game: where the game
# has a generic breed name of its own (`loc_breed_berzerker_generic_name` = "Ragers" = 狂暴者) that
# wording is used - it is the game saying "the breed, not the faction variant" - and where it has
# none, the official name minus the faction word (血痂 / 渣滓 / 瘟疫 / 猎手) the short English form
# leaves out, which is the same wording the game's own compound keeps where it has one
# ("Monstrosity Hunter" = 怪物猎手 / 巨獸獵人). Nothing about the breed is invented; only the faction
# prefix the source did not say is dropped.
# The plural is listed too, because a real mod string does list breeds: "Maulers, Crushers,
# Bulwarks, Pack Masters, Captains/Twins and Monstrosities" (Enhanced_descriptions). It is a second
# source spelling with the same value, not a matcher rule - a rule would also "fix" the plurals of
# languages that inflect, where the target value here is deliberately the singular. The four breeds
# whose generic name the export already carries (Ragers, Flamers, Gunners, Shotgunners) are shadowed
# by it, which is why only their singular spelling comes from here.
#
# Deliberately absent:
#   * "Bruiser" - the export already owns that bare word: the Ogryn talent of that name
#     (loc_talent_ogryn_cooldown_on_elite_kills) is 巨汉, and the export is authoritative for its own
#     strings. A breed list writes "Bruisers", which is still left to the engine rather than risk
#     putting a talent's name in an enemy list.
#   * the plural of the four breeds the export carries a generic name for (Ragers, Flamers, Gunners,
#     Shotgunners) - the game's own generic wording wins, and it is emitted by the export section.
#   * "Groaner", "Daemonhost", "Grenadier", "Bulwark", "Reaper", "Mutant", "Poxwalker" - the export
#     already carries these as terms of their own.
#   * "Captain" and "Twins" are the boss pair, and neither is in the collected strings. The boss
#     nameplates stay English in every language (the game shows "Rodin Karnak" / "Rinda Karnak", and
#     the breed row `loc_breed_display_name_renegade_captain` is the *Scab* Captain = 血痂头目, which
#     stays authoritative for that longer spelling). 连长 is what the Chinese client's dialogue calls
#     the boss - the player's own reading of the game - and 双子 is the community's word for the pair;
#     engines turn the bare "Twins" into 双生.
#   * "Disabler" has no string anywhere in the game; 控制型敌人 is the wording the Chinese mod UIs use.
SHORT_BREEDS = [
    # what a mod writes      its plural            the game's wording, all 11 target languages
    # The values come from the localization index: the breed's own display row where the game has a
    # short form (Mauler!, Sniper, Vanguard, Pox Burster), otherwise its full display name minus the
    # faction word (Scab Mauler 血痂重锤兵, Dreg Stalker 渣滓潜行者), otherwise the generic plural row
    # (Ragers / Flamers / Gunners / Shotgunners - those four plurals are emitted by the export).
    ("Mauler",      "Maulers",      {"zh-cn": "重锤兵", "zh-tw": "重錘兵", "ja": "マウラー", "ko": "마울러", "ru": "Палач", "de": "Schläger", "fr": "Mutileur", "es": "Despedazador", "it": "Mazzolatore", "pl": "Miażdżyciel", "pt-br": "Algoz"}),
    ("Sniper",      "Snipers",      {"zh-cn": "狙击手", "zh-tw": "狙擊手", "ja": "スナイパー", "ko": "저격수", "ru": "Снайпер", "de": "Scharfschütze", "fr": "Sniper", "es": "Francotirador", "it": "Cecchino", "pl": "Snajper", "pt-br": "Franco atirador"}),  # the game's plural row is left untranslated in every language, so one wording covers both
    ("Rager",       "Ragers",       {"zh-cn": "狂暴者", "zh-tw": "暴怒者", "ja": "レイジャー", "ko": "레이거", "ru": "Буйный", "de": "Berserker", "fr": "Furax", "es": "Furia", "it": "Furioso", "pl": "Wściekun", "pt-br": "Furioso"}),      # Dreg Rager; the plural comes from the export
    ("Flamer",      "Flamers",      {"zh-cn": "火焰兵", "zh-tw": "噴火兵", "ja": "フレイマー", "ko": "플레이머", "ru": "Огнеметчик", "de": "Flammenwerfer", "fr": "Incendiaire", "es": "Lanzallamas", "it": "Sparafiamme", "pl": "Spalacz", "pt-br": "Flamejante"}),      # the plural comes from the export
    ("Bomber",      "Bombers",      {"zh-cn": "轰炸者", "zh-tw": "轟炸者", "ja": "ボマー", "ko": "폭탄병", "ru": "Взрывун", "de": "Bomber", "fr": "Bombardier", "es": "Bombardero", "it": "Bombardiere", "pl": "Bombowiec", "pt-br": "Granadeiro"}),      # Scab Bomber 血痂轰炸者
    ("Tox Bomber",  "Tox Bombers",  {"zh-cn": "剧毒轰炸者", "zh-tw": "劇毒轟炸者", "ja": "トックス・ボマー", "ko": "독성 폭탄병", "ru": "Токсичный взрывун", "de": "Gift-Bomber", "fr": "Bombardier toxique", "es": "Bombardero Tóxico", "it": "Bombardiere tossico", "pl": "Toksybombowiec", "pt-br": "Granadeiro Tóxico"}),  # Dreg Tox Bomber
    ("Pox Burster", "Pox Bursters", {"zh-cn": "瘟疫爆破者", "zh-tw": "瘟疫爆破者", "ja": "ポックスバースター", "ko": "폭스 버스터", "ru": "Чумной Взрывун", "de": "Pockenspeier", "fr": "Explosible vérolé", "es": "Reventador de plaga", "it": "Spargipeste", "pl": "Rozpylacz wysypki", "pt-br": "Estourador de peste"}),    # the game spells it both "Pox Burster" and "Poxburster"
    ("Gunner",      "Gunners",      {"zh-cn": "炮手", "zh-tw": "槍手", "ja": "ガンナー", "ko": "거너", "ru": "Пулеметчик", "de": "Kanonier", "fr": "Mitrailleur", "es": "Artillero", "it": "Cannoniere", "pl": "Strzelec", "pt-br": "Atirador"}),        # the plural comes from the export
    ("Stalker",     "Stalkers",     {"zh-cn": "潜行者", "zh-tw": "潛行者", "ja": "ストーカー", "ko": "스토커", "ru": "Охотник", "de": "Schleicher", "fr": "Stalker", "es": "Acechadora", "it": "Persecutore", "pl": "Tropiciel", "pt-br": "Perseguidor"}),      # Dreg Stalker minus the faction word
    ("Vanguard",    "Vanguards",    {"zh-cn": "先锋", "zh-tw": "先鋒", "ja": "先駆け", "ko": "선봉", "ru": "Авангард", "de": "Vorhut", "fr": "Avant-garde", "es": "Vanguardia", "it": "Avanguardia", "pl": "Straż przednia", "pt-br": "Vanguarda"}),        # Scab Vanguard 疤痂先锋 (the game's own typo)
    ("Shotgunner",  "Shotgunners",  {"zh-cn": "霰弹枪手", "zh-tw": "霰彈槍手", "ja": "ショットガンナー", "ko": "샷거너", "ru": "Стрелок", "de": "Schroter", "fr": "Plombeur", "es": "Escopetero", "it": "Fuciliere", "pl": "Strzelbowy", "pt-br": "Escopeteiro"}),    # the plural comes from the export
    ("Trapper",     "Trappers",     {"zh-cn": "陷阱手", "zh-tw": "陷阱兵", "ja": "トラッパー", "ko": "트래퍼", "ru": "Ловушечник", "de": "Jäger", "fr": "Trappeur", "es": "Trampero", "it": "Cacciatore", "pl": "Sidlarz", "pt-br": "Caçador"}),      # Scab Trapper 血痂陷阱手 (the bark uses feminine forms)
    ("Hound",       "Hounds",       {"zh-cn": "猎犬", "zh-tw": "獵犬", "ja": "ハウンド", "ko": "하운드", "ru": "Гончая", "de": "Hund", "fr": "Cerbère", "es": "Perro", "it": "Segugio", "pl": "Ogar", "pt-br": "Cão"}),        # Pox Hound 瘟疫猎犬
    ("Monstrosity", "Monstrosities", {"zh-cn": "怪物", "zh-tw": "巨獸", "ja": "バケモノ", "ko": "흉물", "ru": "Чудовище", "de": "Monstrosität", "fr": "Monstruosité", "es": "Monstruosidad", "it": "Mostruosità", "pl": "Szkaradztwo", "pt-br": "Monstruosidade"}),        # Monstrosity Hunter 怪物猎手 / 巨獸獵人
    ("Captain",     "Captains",     {"zh-cn": "连长", "zh-tw": "連長", "ja": "キャプテン", "ko": "캡틴", "ru": "Капитан", "de": "Captain", "fr": "Capitaine", "es": "Capitán", "it": "Capitano", "pl": "Kapitan", "pt-br": "Capitão"}),        # the boss: Chinese keeps the dialogue word, the rest is the game's own "Captain"
    ("Twins",       None,           {"zh-cn": "双子", "zh-tw": "雙子"}),        # no string to read (the game keeps Rodin/Rinda), so the community wording stays Chinese only
    ("Disabler",    "Disablers",    {"zh-cn": "控制型敌人", "zh-tw": "控制型敵人"}),  # no official string anywhere
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

    # Three labels the game does localise (loc_settings_menu_on / loc_setting_checkbox_on = 开 / 开启,
    # loc_settings_menu_group_other_settings = 其他, loc_popup_button_confirm = 确认), but which the
    # term filter drops as ordinary words - so they reach the glossary from here or not at all. All
    # three are in the module's LABEL_ONLY_WORDS: "other" and "confirm" were added with them, because
    # real mod text uses both in prose ("Compared against the other side", "Confirm Name") and masking
    # those would cost more than it gains.
    #
    # The values are the game's own, all 12 languages. "On" is the one word where the game has two
    # spellings: the checkbox row (开启 / 開啟 / Avec / Sí / …) and the settings-menu row (开 / 開 /
    # Activé / Activado / …). Chinese takes the checkbox row (it pairs with 关闭), French and Spanish
    # take the menu row - "Avec" and "Sí" read as "with" and "yes" next to a label - and every other
    # language is identical in both rows.
    ("On",         {"zh-cn": "开启", "zh-tw": "開啟", "ja": "オン", "ko": "켜기", "ru": "Вкл.", "de": "An", "fr": "Activé", "es": "Activado", "it": "On", "pl": "Wł.", "pt-br": "Ligado"}),
    ("Other",      {"zh-cn": "其他", "zh-tw": "其他", "ja": "その他", "ko": "기타", "ru": "Другое", "de": "Sonstiges", "fr": "Autres", "es": "Otros", "it": "Altro", "pl": "Pozostałe", "pt-br": "Outros"}),
    ("Confirm",    {"zh-cn": "确认", "zh-tw": "確認", "ja": "確定", "ko": "확인", "ru": "Принять", "de": "Bestätigen", "fr": "Confirmer", "es": "Confirmar", "it": "Conferma", "pl": "Potwierdź", "pt-br": "Confirmar"}),
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
for en, plural, _ in SHORT_BREEDS:
    hand_keys.add(en.lower())
    if plural:
        hand_keys.add(plural.lower())
for text in AUTONYMS:
    hand_keys.add(text.lower())

for en, vals in parse_existing(OUT).items():
    if en in hand_keys:
        continue
    # The previous file is not a way back in for a word this build rejects. Its keys are lowercased,
    # so the test has to accept that form (it does - the mark pattern is case-insensitive), and
    # without this gate every rejected term returned on the next run: the mark designations removed
    # on 2026-09-29 came back as "mk vii" entries because the generated section had dropped them and
    # this loop set them down again. Values for the terms that *are* still terms are unaffected.
    if not is_term(en):
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
lines.append('--     localisation, read for all 12 languages out of the localisation index')
lines.append('--     (game-data/index/localization.sqlite) for the keys translations/term_keys.lua lists')
lines.append('--   * Ukrainian values were extracted from the complete community translation')
lines.append('--     "Ukrainian Localization" (Nexus 618); the game ships no Ukrainian itself')
lines.append('--   * the hand verified block lists mechanics wording that has no loc key of its')
lines.append('--     own (Blitz / Keystone / Aura / ...), taken from the official wording')
lines.append('--   * short breed names a mod UI writes ("Mauler" for the game\'s "Scab Mauler") carry')
lines.append('--     that official name minus the faction word the short English form leaves out')
lines.append('--')
lines.append('-- A term is only used for languages that have a value; empty ones are skipped.')
lines.append('--')
lines.append('-- NOTE: this file is generated by tools/build_glossary.py (index values for the key list')
lines.append('-- plus the hand verified block in that script). Re-run it after a game update or after')
lines.append('-- adding keys — manual edits to this file will be overwritten.')
lines.append('return {')
lines.append('    terms = {')
lines.append('        -- hand verified core mechanics (no game loc key exists for these)')
# `emitted` records what the hand-verified blocks actually wrote, so the exported section
# below cannot write the same source word a second time - which is why the file used to carry
# a duplicate of every hand-written term, and one more after every re-run.
emitted = set()
hand_used = 0
hand_shadowed = []
for en, vals in HAND:
    vals = with_uk(en, vals)
    if en.lower() in exported_keys:
        # A collection round has resolved the key that carries this term, and the export carries all
        # 12 languages for it - the same shadow rule the blocks below use, so the hand row steps
        # aside instead of overriding the game's own (and more complete) row.
        hand_shadowed.append(en)
        continue
    hand_used += 1
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
    vals = with_uk(en, vals)
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
lines.append('        -- short breed names a mod UI writes, and their plural: the official row is the')
lines.append('        -- full name ("Scab Mauler"), so a string that says only "Mauler" never matched it')
# Same shadow rule as MISSING_LOC: if a round ever collects one of these as a string of its own, the
# game's wording is authoritative and this row steps aside.
breed_shadowed = []
breed_used = 0
for en, plural, vals in SHORT_BREEDS:
    vals = with_uk(en, with_uk(plural or en, vals))
    for spelling in [en] + ([plural] if plural else []):
        if spelling.lower() in exported_keys:
            breed_shadowed.append(spelling)
            continue
        breed_used += 1
        emitted.add(spelling.lower())
        parts = ['en = ' + quote(spelling)]
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
    vals = with_uk(en, vals)
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
    vals = with_uk(en, vals)
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
      % (len(terms), hand_used, missing_used, ui_used, langs_used, len(AUTONYMS), len(skipped)))
if hand_shadowed:
    print('hand verified mechanics the export now has (kept the game wording): %s'
          % ', '.join(hand_shadowed))
if missing_shadowed:
    print('uncollected game terms the export now has (kept the game wording): %s'
          % ', '.join(missing_shadowed))
if ui_shadowed:
    print('UI labels the game already localises (kept the game wording): %s'
          % ', '.join(ui_shadowed))
if lang_shadowed:
    print('language names the game already localises (kept the game wording): %s'
          % ', '.join(lang_shadowed))
print('short breed names written: %d (of %d listed; %d shadowed by an export)'
      % (breed_used, sum(2 if plural else 1 for _, plural, _ in SHORT_BREEDS), len(breed_shadowed)))
if breed_shadowed:
    print('short breed names the export now has (kept the game wording): %s'
          % ', '.join(breed_shadowed))
multi = sum(1 for l in terms.values() if len(l) >= 12)
print('terms with >=12 languages: %d' % multi)
print('\n--- skipped (not a bare term) ---')
for k, en in skipped[:12]:
    print('  %-52s en=%s' % (k, en[:40]))
print('\n--- sample ---')
for key in list(sorted(terms.keys()))[:10]:
    l = terms[key]
    print('  %-22s zh=%-8s ja=%-10s ru=%-14s uk=%s' % (l.get('en', '')[:20], l.get('zh-cn', '-')[:8], l.get('ja', '-')[:8], l.get('ru', '-')[:12], l.get('uk', '-')[:14]))
