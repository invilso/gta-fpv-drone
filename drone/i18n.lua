-- UI strings, EN + UA. Every user-visible label in the modern menu goes
-- through t() -- adding a language = adding a table here. Keys missing
-- from the active language fall back to English (and to the key itself
-- as a last resort, so a typo'd key is visible in the UI, not invisible).
local M = {}

M.lang = 'en'
M.LANGS = {'en', 'ua'}

local S = {}

S.en = {
    -- sections
    sec_fly = 'Fly', sec_controller = 'Controller', sec_camera = 'Camera',
    sec_world = 'World', sec_audio = 'Audio', sec_osd = 'OSD',
    sec_replay = 'Replay', sec_advanced = 'Advanced',
    -- status bar
    st_flying = 'Flying', st_grounded = 'Landed', st_crashed = 'Crashed',
    st_idle = 'Standby', st_no_controller = 'No controller',
    st_replaying = 'Replay',
    -- common
    expert_mode = 'Expert', search_hint = 'Search settings...',
    lang_toggle = 'UA', -- shows the language you'd switch TO
    on = 'On', off = 'Off',
    -- fly section
    fly_profiles = 'Drone profiles',
    fly_mode = 'Flight mode',
    fly_3d = '3D throttle (inverted flight)',
    fly_3d_hint = 'Stick center = hover, bottom half = downward thrust. How real acro quads fly.',
    profile_whoop_title = 'Whoop',
    profile_racer_title = 'Racer',
    profile_heavy_title = 'Heavy',
    profile_default_title = 'Standard',
    profile_whoop_desc = 'Tiny and gentle. Living-room flying.',
    profile_racer_desc = 'Fast and twitchy. Race-track energy.',
    profile_heavy_desc = 'Big and stable. Cinematic lifts.',
    profile_default_desc = 'Balanced all-rounder. Start here.',
    profile_custom_desc = 'Your own tune. Physics editor below.',
    profile_active = 'Active',
    profile_select = 'Select',
}

S.ua = {
    sec_fly = 'Політ', sec_controller = 'Контролер', sec_camera = 'Камера',
    sec_world = 'Світ', sec_audio = 'Звук', sec_osd = 'OSD',
    sec_replay = 'Реплеї', sec_advanced = 'Експертне',
    st_flying = 'У польоті', st_grounded = 'На землі', st_crashed = 'Розбитий',
    st_idle = 'Очікування', st_no_controller = 'Немає контролера',
    st_replaying = 'Реплей',
    expert_mode = 'Експерт', search_hint = 'Пошук налаштувань...',
    lang_toggle = 'EN',
    on = 'Увімк', off = 'Вимк',
    fly_profiles = 'Профілі дрона',
    fly_mode = 'Режим польоту',
    fly_3d = '3D-газ (інвертований політ)',
    fly_3d_hint = 'Центр стіка = зависання, нижня половина = тяга вниз. Так літають справжні акро-квадрики.',
    profile_whoop_title = 'Вуп',
    profile_racer_title = 'Рейсер',
    profile_heavy_title = 'Важкий',
    profile_default_title = 'Стандарт',
    profile_whoop_desc = 'Малий і лагідний. Політ по кімнаті.',
    profile_racer_desc = 'Швидкий і різкий. Трекова енергія.',
    profile_heavy_desc = 'Великий і стабільний. Кінозйомка.',
    profile_default_desc = 'Збалансований універсал. Починай з нього.',
    profile_custom_desc = 'Твій власний тюн. Редактор фізики нижче.',
    profile_active = 'Активний',
    profile_select = 'Обрати',
}

function M.t(key)
    local d = S[M.lang]
    return (d and d[key]) or S.en[key] or key
end

function M.set(lang)
    if S[lang] then M.lang = lang end
end

return M
