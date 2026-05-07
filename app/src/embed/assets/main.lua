if love.system.getOS() == "Windows" then
    os.execute("chcp 65001 > nul")
    io.stdout:setvbuf("no")
end

local CHIP_COLORS_ALL = {
    "#6e99c4", "#7ee0d8", "#b591f2", "#bdf0c2", "#f0e5bd", "#f0bdd9"
}

local function shuffledColors(n)
    local pool = {}
    for _,v in ipairs(CHIP_COLORS_ALL) do pool[#pool+1] = v end
    for i = #pool, 2, -1 do
        local j = love.math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local result = {}
    for i = 1, math.min(n, #pool) do result[i] = pool[i] end
    return result
end
local CHIP_R      = 16
local ARENA_W     = 1260
local ARENA_H     = 1260
local ARENA_RX    = 80   -- радиус скругления

local WALL_COLOR  = { 0x6a/255, 0x6a/255, 0x6a/255 }  -- светлее загрузочного серого
local WALL_RX     = 10    -- скругление углов стены
local WALL_COUNT  = 14    -- больше стен, покрывают всю карту
local WALL_THICK  = 22    -- чуть тоньше
local WALL_MIN_LEN= 110   -- мин длина (короче)
local WALL_MAX_LEN= 230   -- макс длина (короче)
local walls       = {}    -- { x, y, w, h }  — в мировых координатах, центр в 0,0
local FRICTION    = 0.91
local MIN_SPEED   = 5
local SLING_MAX   = 200
local BOT_THINK   = 0.9  -- секунд "думает" бот
local NUM_BUBBLES = 45

local FRUIT_R          = 22  -- чуть больше CHIP_R (16)
local foodImages       = {}  -- заполняется в love.load
local fruit            = nil -- текущий фрукт на карте (nil = нет)
local fruitTurnCounter = 0   -- счётчик ходов

local function drawFruit()
    if not fruit then return end
    local img = fruit.img
    if not img then
        love.graphics.setColor(1, 0.85, 0.2, 0.82)
        love.graphics.circle("fill", fruit.x, fruit.y, FRUIT_R)
        return
    end
    local iw, ih = img:getDimensions()
    local scale = (FRUIT_R * 2) / math.max(iw, ih)
    love.graphics.setColor(1, 1, 1, 0.82)
    love.graphics.draw(img, fruit.x, fruit.y, 0, scale, scale, iw/2, ih/2)
end

local particles = {}
local blood     = {}  -- пятна крови, остаются на полу навсегда
local BR, BG, BB = 184/255, 169/255, 154/255

local function spawnParticles(x, y, count, rMin, rMax, speedMult, lifetime)
    for _ = 1, count do
        local angle = love.math.random() * math.pi * 2
        local speed = (love.math.random() * 0.6 + 0.4) * speedMult
        particles[#particles+1] = {
            x = x, y = y,
            vx = math.cos(angle) * speed,  -- пикселей/сек
            vy = math.sin(angle) * speed,
            r  = 3,
            t  = 0,
            life = lifetime,
        }
    end
end

local bloodDrops = {}  -- { x, y, vx, vy, r, t }

local function updateBloodDrops(dt)
    local i = 1
    while i <= #bloodDrops do
        local d = bloodDrops[i]
        d.x  = d.x + d.vx * dt
        d.y  = d.y + d.vy * dt
        d.vx = d.vx * (1 - dt * 2.5)
        d.vy = d.vy * (1 - dt * 2.5)
        d.t  = d.t + dt
        local speed = math.sqrt(d.vx*d.vx + d.vy*d.vy)
        if speed < 8 or d.t > 1.2 then
            blood[#blood+1] = { x=d.x, y=d.y, r=d.r*(0.8+love.math.random()*0.6), a=love.math.random()*0.4+0.25, blob=false, jr=d.jr, jg=d.jg, jb=d.jb }
            table.remove(bloodDrops, i)
        else
            i = i + 1
        end
    end
end

local function spawnBlood(x, y, spread, blobR, bloodT)
    bloodT = bloodT or 0
    local clusterCount = math.floor(blobR * 1.4 + 8)
    for _ = 1, clusterCount do
        local angle = love.math.random() * math.pi * 2
        local d     = love.math.random() ^ 0.5 * blobR * 0.9
        blood[#blood+1] = {
            x  = x + math.cos(angle) * d,
            y  = y + math.sin(angle) * d,
            r  = love.math.random() * 4.5 + 1.5,
            a  = 0.22 + love.math.random() * 0.22,
            blob = true,
        }
    end
    local drops = math.floor(spread * 0.9 + 6)
    for _ = 1, drops do
        local angle = love.math.random() * math.pi * 2
        local d     = love.math.random() ^ 0.6 * spread
        blood[#blood+1] = {
            x  = x + math.cos(angle) * d,
            y  = y + math.sin(angle) * d,
            r  = love.math.random() * 3.0 + 0.6,
            a  = love.math.random() * 0.45 + 0.2,
            blob = false,
        }
    end
    if bloodT > 0.35 then
        local flyCount = math.floor(bloodT * 14 + 2)
        for _ = 1, flyCount do
            local angle = love.math.random() * math.pi * 2
            local spd   = (80 + bloodT * 320) * (0.5 + love.math.random() * 0.5)
            bloodDrops[#bloodDrops+1] = {
                x  = x, y  = y,
                vx = math.cos(angle) * spd,
                vy = math.sin(angle) * spd,
                r  = love.math.random() * 2.5 + 0.8,
                t  = 0,
            }
        end
    end
end

local function updateParticles(dt)
    local i = 1
    while i <= #particles do
        local p = particles[i]
        p.t  = p.t + dt
        p.x  = p.x + p.vx * dt
        p.y  = p.y + p.vy * dt
        local drag = 1 - dt * 3
        if drag < 0 then drag = 0 end
        p.vx = p.vx * drag
        p.vy = p.vy * drag
        local outOfBounds = math.abs(p.x) > ARENA_W/2 + 60 or math.abs(p.y) > ARENA_H/2 + 60
        if p.t >= p.life or outOfBounds then
            table.remove(particles, i)
        else
            i = i + 1
        end
    end
end

local function drawBlood()
    for _,b in ipairs(blood) do
        love.graphics.setColor(b.jr or BR, b.jg or BG, b.jb or BB, b.a)
        love.graphics.circle("fill", b.x, b.y, b.r)
    end
    for _,d in ipairs(bloodDrops) do
        love.graphics.setColor(d.jr or BR, d.jg or BG, d.jb or BB, 0.35)
        love.graphics.circle("fill", d.x, d.y, d.r)
    end
end

local function drawParticles()
    for _,p in ipairs(particles) do
        local fadeStart = p.life * 0.35
        local alpha
        if p.t < fadeStart then
            alpha = 1
        else
            alpha = 1 - (p.t - fadeStart) / (p.life - fadeStart)
        end
        love.graphics.setColor(0, 0, 0, alpha * 0.82)
        love.graphics.circle("fill", p.x, p.y, p.r)
    end
end

local function hex(s)
    return tonumber(s:sub(2,3),16)/255,
           tonumber(s:sub(4,5),16)/255,
           tonumber(s:sub(6,7),16)/255
end

local JUICE_COLORS = {
    "#f1f2bf", "#96b08d", "#a6353b", "#962d70", "#e8e0d0",
}

local function spawnJuice(x, y, colorHex)
    local jr, jg, jb = hex(colorHex)
    local clusterCount = math.floor(FRUIT_R * 1.4 + 8)
    for _ = 1, clusterCount do
        local angle = love.math.random() * math.pi * 2
        local d     = love.math.random() ^ 0.5 * FRUIT_R * 0.9
        blood[#blood+1] = {
            x=x+math.cos(angle)*d, y=y+math.sin(angle)*d,
            r=love.math.random()*4.5+1.5,
            a=0.22+love.math.random()*0.22, blob=true,
            jr=jr, jg=jg, jb=jb,
        }
    end
    local spread = FRUIT_R * 2.5
    for _ = 1, 12 do
        local angle = love.math.random()*math.pi*2
        local d = love.math.random()^0.6 * spread
        blood[#blood+1] = {
            x=x+math.cos(angle)*d, y=y+math.sin(angle)*d,
            r=love.math.random()*3.0+0.6,
            a=love.math.random()*0.35+0.15, blob=false,
            jr=jr, jg=jg, jb=jb,
        }
    end
    for _ = 1, 8 do
        local angle = love.math.random()*math.pi*2
        local spd = 100+love.math.random()*220
        bloodDrops[#bloodDrops+1] = {
            x=x, y=y, vx=math.cos(angle)*spd, vy=math.sin(angle)*spd,
            r=love.math.random()*2.5+0.8, t=0,
            jr=jr, jg=jg, jb=jb,
        }
    end
end

local function setBlack(a)
    love.graphics.setColor(hex("#111111"), a or 1)
end

local function setCol(h6, a)
    local r,g,b = hex(h6)
    love.graphics.setColor(r, g, b, a or 1)
end

local function printBold(font, text, x, y)
    local xi,yi = math.floor(x), math.floor(y)
    love.graphics.setFont(font)
    love.graphics.print(text, xi,   yi)
    love.graphics.print(text, xi+1, yi)
    love.graphics.print(text, xi+2, yi)
end

local function printBoldCenter(font, text, cx, y)
    local lw = font:getWidth(text)+2
    printBold(font, text, cx - lw/2, y)
end

local function hitBox(x,y,w,h,mx,my)
    return mx>=x and mx<=x+w and my>=y and my<=y+h
end

local function hitBtnCenter(font, text, cx, cy, mx, my)
    local lw = font:getWidth(text)+2
    local bh = font:getHeight()
    return hitBox(cx-lw/2-10, cy-5, lw+20, bh+10, mx, my)
end

local function dist(ax,ay,bx,by)
    local dx,dy = ax-bx, ay-by
    return math.sqrt(dx*dx+dy*dy)
end

local bubbles = {}

local function newBubble(y)
    local sw = love.graphics.getWidth()
    return {
        x=love.math.random(20,sw-20), y=y or love.math.random(-60,-10),
        r=love.math.random(5,18), speed=love.math.random(30,80),
        wobble=love.math.random()*math.pi*2,
        wobbleSpeed=love.math.random(1,3)+love.math.random(),
        wobbleAmp=love.math.random(4,14),
    }
end

local function updateBubbles(dt)
    local h = love.graphics.getHeight()
    for _,b in ipairs(bubbles) do
        b.y = b.y + b.speed*dt
        b.wobble = b.wobble + b.wobbleSpeed*dt
        b.x = b.x + math.sin(b.wobble)*b.wobbleAmp*dt*3.5
        if b.y-b.r > h+20 then
            local nb=newBubble(); b.x=nb.x;b.y=nb.y;b.r=nb.r
            b.speed=nb.speed;b.wobble=nb.wobble
            b.wobbleSpeed=nb.wobbleSpeed;b.wobbleAmp=nb.wobbleAmp
        end
    end
end

local function drawBubbles()
    for _,b in ipairs(bubbles) do
        love.graphics.setColor(1,1,1,0.28)
        love.graphics.circle("fill",b.x,b.y,b.r)
    end
end

local curScreen  = "main"
local prevScreen = nil
local animT      = 1
local ANIM_SPD   = 1.6
local lastDt     = 0

local function easeOut(t) return 1-(1-t)^3 end

local function goTo(next)
    prevScreen=curScreen; curScreen=next; animT=0
end

local function goBack()
    local backs={mode="main",solo="mode",game="solo",result="main",loading="solo",secret="main",settings="main",langpick="settings"}
    local p=backs[curScreen]
    if p then prevScreen=curScreen; curScreen=p; animT=0 end
end

local secret = { softBots=false, ultraRicochet=false, aimCollision=true, showFps=false }
local LANGS = {
    "Bosanski",      -- 1
    "Čeština",       -- 2
    "Deutsch",       -- 3
    "English",       -- 4
    "Español",       -- 5
    "Français",      -- 6
    "Hrvatski",      -- 7
    "Italiano",      -- 8
    "Polski",        -- 9
    "Romani",        -- 10
    "Română",        -- 11
    "Slovenčina",    -- 12
    "Slovenščina",   -- 13
    "Srpski",        -- 14
    "Türkçe",        -- 15
    "Авар мацӀ",     -- 16
    "Башҡортса",     -- 17
    "Беларуская",    -- 18
    "Дарган мез",    -- 19
    "Қазақша",       -- 20
    "Коми",          -- 21
    "Лезги чӀал",   -- 22
    "Марий йылме",   -- 23
    "Нохчийн",       -- 24
    "Русский",       -- 25
    "Саха тыла",     -- 26
    "Татарча",       -- 27
    "Удмурт кыл",    -- 28
    "Українська",    -- 29
    "Чӑвашла",       -- 30
    "Эрзянь кель",   -- 31
}
local settings = { lang=1, blood=true, particles=true, ring=true }
local langScroll = 0  -- пикселей прокрутки списка языков

local T = {}

T[1] = {
    play="Igraj", settings="Postavke", solo="Solo", online="Online",
    players="Igrači", borders="Zidovi", fruits="Voće", start="Pokreni",
    settings_title="Postavke", language="Jezik",
    opt_blood="Krv", opt_particles="Čestice", opt_ring="Indikator poteza",
    reset_lang="Resetuj jezik",
    secret_title="Tajni izbornik",
    soft_bots="Botovi bez maks. udarca", ultra="Ultra-rikoše", aim_col="Kolizije za nišan", show_fps="Neki brojač",
    player_win="Igrač pobijedio", ai_win="AI pobijedio",
    again="Ponovo", ok="U redu", draw="Izjednačenje",
}

T[2] = {
    play="Hrát", opt_blood="Krev", opt_particles="Částice", opt_ring="Indikátor tahu", settings="Nastavení", solo="Solo", online="Online",
    players="Hráči", borders="Zdi", fruits="Ovoce", start="Začít",
    settings_title="Nastavení", language="Jazyk", reset_lang="Resetovat jazyk",
    secret_title="Tajná nabídka",
    soft_bots="Boti bez max. úderu", ultra="Ultra-ricochet", aim_col="Kolize pro zaměřovač", show_fps="Nějaký čítač",
    player_win="Hráč vyhrál", ai_win="AI vyhrála",
    again="Znovu", ok="OK", draw="Remíza",
}

T[3] = {
    play="Spielen", opt_blood="Blut", opt_particles="Partikel", opt_ring="Zuganzeige", settings="Einstellungen", solo="Solo", online="Online",
    players="Spieler", borders="Wände", fruits="Früchte", start="Starten",
    settings_title="Einstellungen", language="Sprache", reset_lang="Sprache zurücksetzen",
    secret_title="Geheimes Menü",
    soft_bots="Bots ohne Max.-Schlag", ultra="Ultra-Ricochet", aim_col="Kollisionen für Zielvisier", show_fps="Irgendein Zähler",
    player_win="Spieler hat gewonnen", ai_win="KI hat gewonnen",
    again="Nochmal", ok="OK", draw="Unentschieden",
}

T[4] = {
    play="Play", opt_blood="Blood", opt_particles="Particles", opt_ring="Turn indicator", settings="Settings", solo="Solo", online="Online",
    players="Players", borders="Walls", fruits="Fruits", start="Start",
    settings_title="Settings", language="Language", reset_lang="Reset language",
    secret_title="Secret Menu",
    soft_bots="Bots without max hit", ultra="Ultra-ricochet", aim_col="Aim collisions", show_fps="Some counter",
    player_win="Player wins", ai_win="AI wins", draw="Draw",
    again="Again", ok="OK",
}

T[5] = {
    play="Jugar", opt_blood="Sangre", opt_particles="Partículas", opt_ring="Indicador de turno", settings="Ajustes", solo="Solo", online="En línea",
    players="Jugadores", borders="Paredes", fruits="Frutas", start="Empezar",
    settings_title="Ajustes", language="Idioma", reset_lang="Restablecer idioma",
    secret_title="Menú secreto",
    soft_bots="Bots sin golpe máx.", ultra="Ultra-ricochete", aim_col="Colisiones para la mira", show_fps="Algún contador",
    player_win="El jugador ganó", ai_win="La IA ganó",
    again="De nuevo", ok="OK", draw="Empate",
}

T[6] = {
    play="Jouer", opt_blood="Sang", opt_particles="Particules", opt_ring="Indicateur de tour", settings="Paramètres", solo="Solo", online="En ligne",
    players="Joueurs", borders="Murs", fruits="Fruits", start="Commencer",
    settings_title="Paramètres", language="Langue", reset_lang="Réinitialiser la langue",
    secret_title="Menu secret",
    soft_bots="Bots sans frappe max.", ultra="Ultra-ricochet", aim_col="Collisions pour la visée", show_fps="Un truc qui compte",
    player_win="Le joueur a gagné", ai_win="L'IA a gagné",
    again="Rejouer", ok="OK", draw="Égalité",
}

T[7] = {
    play="Igraj", settings="Postavke", solo="Solo", online="Online",
    players="Igrači", borders="Zidovi", fruits="Voće", start="Pokreni",
    settings_title="Postavke", language="Jezik", opt_blood="Krv", opt_particles="Čestice", opt_ring="Indikator poteza", reset_lang="Resetiraj jezik",
    secret_title="Tajni izbornik",
    soft_bots="Botovi bez maks. udarca", ultra="Ultra-rikoše", aim_col="Kolizije za nišan", show_fps="Neki brojač",
    player_win="Igrač pobijedio", ai_win="AI pobijedio",
    again="Ponovo", ok="U redu", draw="Izjednačenje",
}

T[8] = {
    play="Giocare", settings="Impostazioni", solo="Solo", online="Online",
    players="Giocatori", borders="Muri", fruits="Frutta", start="Inizia",
    settings_title="Impostazioni", language="Lingua", reset_lang="Reimposta lingua",
    secret_title="Menu segreto",
    soft_bots="Bot senza colpo max.", ultra="Ultra-rimbalzo", aim_col="Collisioni per il mirino", show_fps="Un contatore",
    player_win="Il giocatore ha vinto", ai_win="L'IA ha vinto",
    again="Di nuovo", ok="OK", draw="Pareggio",
    opt_blood="Sangue", opt_particles="Particelle", opt_ring="Indicatore di turno",
}

T[9] = {
    play="Graj", opt_blood="Krew", opt_particles="Cząsteczki", opt_ring="Wskaźnik tury", settings="Ustawienia", solo="Solo", online="Online",
    players="Gracze", borders="Ściany", fruits="Owoce", start="Zacznij",
    settings_title="Ustawienia", language="Język", reset_lang="Resetuj język",
    secret_title="Tajne menu",
    soft_bots="Boty bez maks. uderzenia", ultra="Ultra-rykoszet", aim_col="Kolizje dla celownika", show_fps="Jakiś licznik",
    player_win="Gracz wygrał", ai_win="AI wygrała",
    again="Znowu", ok="OK", draw="Remis",
}

T[10] = {
    play="Khelel", opt_blood="Rat", opt_particles="Cikne tikne", opt_ring="Kheldipe signal", settings="Parametruri", solo="Jekh", online="Online",
    players="Kheledenge", borders="Murura", fruits="Fruktura", start="Shurui",
    settings_title="Parametruri", language="Chib", reset_lang="Resetinel chib",
    secret_title="Gojipen meniu",
    soft_bots="Bota bi max. mukljipe", ultra="Ultra-rikoshet", aim_col="Kolizii le nishanistar", show_fps="Nu știu",
    player_win="O kheledeno dzhindas", ai_win="O IA dzhindas",
    again="Pale", ok="Baxtalipe", draw="Barabar",
}

T[11] = {
    play="Joacă", opt_blood="Sânge", opt_particles="Particule", opt_ring="Indicator de tur", settings="Setări", solo="Solo", online="Online",
    players="Jucători", borders="Pereți", fruits="Fructe", start="Începe",
    settings_title="Setări", language="Limbă", reset_lang="Resetează limba",
    secret_title="Meniu secret",
    soft_bots="Boți fără lovitură max.", ultra="Ultra-ricoșeu", aim_col="Coliziuni pentru vizare", show_fps="Un contor oarecare",
    player_win="Jucătorul a câștigat", ai_win="IA a câștigat",
    again="Din nou", ok="OK", draw="Egal",
}

T[12] = {
    play="Hrať", opt_blood="Krv", opt_particles="Častice", opt_ring="Indikátor ťahu", settings="Nastavenia", solo="Solo", online="Online",
    players="Hráči", borders="Steny", fruits="Ovocie", start="Začať",
    settings_title="Nastavenia", language="Jazyk", reset_lang="Resetovať jazyk",
    secret_title="Tajná ponuka",
    soft_bots="Boti bez max. úderu", ultra="Ultra-ricošet", aim_col="Kolízie pre mieridlo", show_fps="Nejaký počítadlo",
    player_win="Hráč vyhral", ai_win="AI vyhrala",
    again="Znovu", ok="OK", draw="Remíza",
}

T[13] = {
    play="Igraj", settings="Nastavitve", opt_blood="Kri", opt_particles="Delci", opt_ring="Indikator poteze", solo="Solo", online="Online",
    players="Igralci", borders="Stene", fruits="Sadje", start="Začni",
    settings_title="Nastavitve", language="Jezik", reset_lang="Ponastavi jezik",
    secret_title="Skrivni meni",
    soft_bots="Boti brez maks. udarca", ultra="Ultra-rikoše", aim_col="Trki za merišče", show_fps="Nek števec",
    player_win="Igralec je zmagal", ai_win="AI je zmagal",
    again="Znova", ok="V redu", draw="Izenačenje",
}

T[14] = {
    play="Играј", opt_blood="Крв", opt_particles="Честице", opt_ring="Индикатор потеза", settings="Подешавања", solo="Соло", online="Онлајн",
    players="Играчи", borders="Зидови", fruits="Воће", start="Почни",
    settings_title="Подешавања", language="Језик", reset_lang="Ресетуј језик",
    secret_title="Тајни мени",
    soft_bots="Ботови без макс. ударца", ultra="Ултра-рикошет", aim_col="Колизије за нишан", show_fps="Неки бројач",
    player_win="Играч победио", ai_win="ВИ победио",
    again="Поново", ok="У реду", draw="Нерешено",
}

T[15] = {
    play="Oyna", opt_blood="Kan", opt_particles="Partiküller", opt_ring="Sıra göstergesi", settings="Ayarlar", solo="Solo", online="Çevrimiçi",
    players="Oyuncular", borders="Duvarlar", fruits="Meyveler", start="Başla",
    settings_title="Ayarlar", language="Dil", reset_lang="Dili sıfırla",
    secret_title="Gizli menü",
    soft_bots="Botlar maks. vuruş yok", ultra="Ultra-rikoşe", aim_col="Nişan çarpışmaları", show_fps="Bir sayaç işte",
    player_win="Oyuncu kazandı", ai_win="YZ kazandı",
    again="Tekrar", ok="Tamam", draw="Beraberlik",
}

T[16] = {
    play="РекӀелел", opt_blood="ЦӀер", opt_particles="ЧӀухал", opt_ring="ХӀед гьавур", settings="Настройкаби", solo="Цолъ", online="Онлайн",
    players="РекӀелел босулел", borders="КӀалъзаби", fruits="ЦӀваби", start="БакӀараб",
    settings_title="Настройкаби", language="МацӀ", reset_lang="МацӀ ккарал гьабуне",
    secret_title="Яхъунаб меню",
    soft_bots="Боташ макс. хъвей бокьо", ultra="Ультра-рикошет", aim_col="Прицелалъ чӀегӀерел", show_fps="Гьеч",
    player_win="РекӀелел босулел толула", ai_win="ИИ толула",
    again="Гьединлъидаса", ok="ХӀа", draw="Ничья",
}

T[17] = {
    play="Уйнарға", opt_blood="Ҡан", opt_particles="Кисәксәләр", opt_ring="Адым күрһәткес", settings="Көйләүҙәр", solo="Яңғыҙ", online="Онлайн",
    players="Уйынсылар", borders="Стеналар", fruits="Еләк-емеш", start="Башларға",
    settings_title="Көйләүҙәр", language="Тел", reset_lang="Телде торғоҙоу",
    secret_title="Йәшерен меню",
    soft_bots="Боттар макс. һуғышһыҙ", ultra="Ультра-рикошет", aim_col="Нишан бәрелештәре", show_fps="Белмәйем",
    player_win="Уйынсы еңде", ai_win="ЯИ еңде",
    again="Ҡабат", ok="Яраны", draw="Тиң",
}

T[18] = {
    play="Гуляць", opt_blood="Кроў", opt_particles="Часціцы", opt_ring="Апавяшчэнне аб хадзе", settings="Налады", solo="Сола", online="Анлайн",
    players="Гульцы", borders="Перашкоды", fruits="Садавіна", start="Пачаць",
    settings_title="Налады", language="Мова", reset_lang="Скінуць мову",
    secret_title="Сакрэтнае меню",
    soft_bots="Боты без макс. ўдару", ultra="Ультрарыкашэт", aim_col="Калізіі для прыцэла", show_fps="Нейкі лічыльнік",
    player_win="Гулец перамог", ai_win="ШІ перамог",
    again="Зноў", ok="Добра", draw="Нічыя",
}

T[19] = {
    play="ХӀяракатлизи", opt_blood="ЦӀудри", opt_particles="Дакъни", opt_ring="ХӀяракат лебниличила", settings="Настройкни", solo="Цаибил", online="Онлайн",
    players="ХӀяракатлизибти", borders="Пяшти", fruits="Мургьи", start="Башес",
    settings_title="Настройкни", language="Мез", reset_lang="Мез дяхӀяэс",
    secret_title="ЧебяхӀти меню",
    soft_bots="Боти макс. хӀяракатличиб боцӀи", ultra="Ультра-рикошет", aim_col="Прицелла бутӀни", show_fps="Хӏябал",
    player_win="ХӀяракатчи чебяхӀ хьанри", ai_win="ИИ чебяхӀ хьанри",
    again="ГьунчӀала", ok="ХӀела", draw="Ничья",
}

T[20] = {
    play="Ойнау", opt_blood="Қан", opt_particles="Бөлшектер", opt_ring="Жүріс индикаторы", settings="Параметрлер", solo="Жеке", online="Онлайн",
    players="Ойыншылар", borders="Қабырғалар", fruits="Жемістер", start="Бастау",
    settings_title="Параметрлер", language="Тіл", reset_lang="Тілді қалпына келтіру",
    secret_title="Құпия мәзір",
    soft_bots="Боттар макс. соқпай", ultra="Ультра-рикошет", aim_col="Нысана соқтығысулары", show_fps="Білмеймін",
    player_win="Ойыншы жеңді", ai_win="ЖИ жеңді",
    again="Қайта", ok="OK", draw="Тең",
}

T[21] = {
    play="Ворсны", opt_blood="Вир", opt_particles="Пыдöссэз", opt_ring="Ход висьтавöм", settings="Настройкаяс", solo="Ӧтнас", online="Онлайн",
    players="Ворсысьяс", borders="Стенаяс", fruits="Емышъяс", start="Кутны",
    settings_title="Настройкаяс", language="Кыв", reset_lang="Кыв бергӧдны",
    secret_title="Шыӧдчытӧм меню",
    soft_bots="Ботъяс макс. вотӧм абу", ultra="Ультрарикошет", aim_col="Коллизияяс прицел вылӧ", show_fps="Ог лыддьысьян",
    player_win="Ворсысь чӧжис", ai_win="ИИ чӧжис",
    again="Мӧдысь", ok="Бур", draw="Тупöдтöм",
}

T[22] = {
    play="Эвел хьун", opt_blood="ЦӀай", opt_particles="Пайяр", opt_ring="Ход малум авун", settings="Настройкаяр", solo="Сад", online="Онлайн",
    players="Эвелзавайбур", borders="Пенер", fruits="Цуьквер", start="Башламишун",
    settings_title="Настройкаяр", language="ЧӀал", reset_lang="ЧӀал элкъуьруьн",
    secret_title="Чукурвал авай меню",
    soft_bots="Боттар макс. ттуп тавуна", ultra="Ультра-рикошет", aim_col="Прицелдин кӀватӀалар", show_fps="Чӏалай аквазвач",
    player_win="Эвелзавайди галукьна", ai_win="ИИ галукьна",
    again="Кьилелай", ok="ХьайитӀа", draw="Яб кьун",
}

T[23] = {
    play="Модаш", opt_blood="Вӱр", opt_particles="Пырче-влак", opt_ring="Ходын палыме", settings="Настройко", solo="Иктӓн", online="Онлайн",
    players="Модышо-влак", borders="Пырдыж", fruits="Саска", start="Тӱҥалаш",
    settings_title="Настройко", language="Йылме", reset_lang="Йылмым пӧртылташ",
    secret_title="Шылше меню",
    soft_bots="Бот-влак макс. сеҥыде", ultra="Ультра-рикошет", aim_col="Прицел перекален", show_fps="Нимат-гынат лыдыме",
    player_win="Модышо сеҥыш", ai_win="ИИ сеҥыш",
    again="Угыч", ok="Йӧра", draw="Тӧр",
}

T[24] = {
    play="Ловзар", opt_blood="Цӏий", opt_particles="Дакъош", opt_ring="Хьаша дӀадаккхар", settings="Нисйарш", solo="Цхьаьна", online="Онлайн",
    players="Ловзархой", borders="Пенаш", fruits="Стоьмаш", start="Долалур",
    settings_title="Нисйарш", language="Мотт", reset_lang="Мотт дӀаяккха",
    secret_title="Дийнаса Ца Хуъу меню",
    soft_bots="Боташ макс. тохарца боцу", ultra="Ультра-рикошет", aim_col="Прицелан догӀанарш", show_fps="Ца хаьа",
    player_win="Ловзархо толу", ai_win="ИИ толу",
    again="Цхьана Схьа", ok="ХӀаъ", draw="Тарло",
}

T[25] = {
    play="Играть", opt_blood="Кровь", opt_particles="Частицы", opt_ring="Оповещение о ходе", settings="Настройки", solo="Соло", online="Онлайн",
    players="Игроки", borders="Преграды", fruits="Фрукты", start="Начать",
    settings_title="Настройки", language="Язык", reset_lang="Сбросить язык",
    secret_title="Секретное меню",
    soft_bots="Боты без макс. удара", ultra="Ультрарикошет", aim_col="Коллизии для прицела", show_fps="Какой-то счётчик",
    player_win="Игрок победил", ai_win="ИИ победил",
    again="Заново", ok="Окей", draw="Ничья",
}

T[26] = {
    play="Оонньуу", opt_blood="Хаан", opt_particles="Чааскыйдар", opt_ring="Ход бэлиэтэ", settings="Туруоруулар", solo="Биирдии", online="Онлайн",
    players="Оонньооччулар", borders="Хабырҕастар", fruits="Үүнээйилэр", start="Саҕала",
    settings_title="Туруоруулар", language="Тыл", reset_lang="Тылы сэргэтии",
    secret_title="Кистэлэҥ мэню",
    soft_bots="Боттар макс. охсуспакка", ultra="Ультра-рикошет", aim_col="Прицел охсуһуулара", show_fps="Билбэппин",
    player_win="Оонньооччу кыайда", ai_win="ИИ кыайда",
    again="Иккитэ", ok="Сөп", draw="Тэҥ",
}

T[27] = {
    play="Уйнарга", opt_blood="Кан", opt_particles="Кисәкчәләр", opt_ring="Адым күрсәткеч", settings="Көйләүләр", solo="Ялгыз", online="Онлайн",
    players="Уенчылар", borders="Стеналар", fruits="Җиләк-җимеш", start="Башларга",
    settings_title="Көйләүләр", language="Тел", reset_lang="Телне кире кую",
    secret_title="Яшерен меню",
    soft_bots="Ботлар макс. сугышсыз", ultra="Ультра-рикошет", aim_col="Нишан бәрелешләре", show_fps="Нидер дә белмим",
    player_win="Уенчы җиңде", ai_win="ЯИ җиңде",
    again="Кабат", ok="Ярый", draw="Тигезлек",
}

T[28] = {
    play="Шудыны", opt_blood="Вир", opt_particles="Пичи люкетъёс", opt_ring="Ход висъян", settings="Настройкаос", solo="Одӥг", online="Онлайн",
    players="Шудӥсьёс", borders="Стенаос", fruits="Емышъёс", start="Кутскыны",
    settings_title="Настройкаос", language="Кыл", reset_lang="Кылэз берыктыны",
    secret_title="Ватэм меню",
    soft_bots="Ботъёс макс. эн сэзьёс", ultra="Ультра-рикошет", aim_col="Прицеллэн тӥяськонэз", show_fps="Öвöл тодӥсько",
    player_win="Шудӥсь бӧрдӥз", ai_win="ИИ бызьыз",
    again="Эшшо", ok="Луоз", draw="Огкадь",
}

T[29] = {
    play="Грати", opt_blood="Кров", opt_particles="Частинки", opt_ring="Сповіщення про хід", settings="Налаштування", solo="Соло", online="Онлайн",
    players="Гравці", borders="Перешкоди", fruits="Фрукти", start="Почати",
    settings_title="Налаштування", language="Мова", reset_lang="Скинути мову",
    secret_title="Таємне меню",
    soft_bots="Боти без макс. удару", ultra="Ультрарикошет", aim_col="Колізії для прицілу", show_fps="Якийсь лічильник",
    player_win="Гравець переміг", ai_win="ШІ переміг",
    again="Знову", ok="Гаразд", draw="Нічия",
}

T[30] = {
    play="Выляма", opt_blood="Юн", opt_particles="Пайсем", opt_ring="Ход пĕлтерĕшĕ", settings="Йĕркелевĕ", solo="Пĕрре", online="Онлайн",
    players="Выляканĕсем", borders="Стенĕсем", fruits="Çимĕçсем", start="Пуçлама",
    settings_title="Йĕркелевĕ", language="Чĕлхе", reset_lang="Чĕлхене тавăр",
    secret_title="Пытанă меню",
    soft_bots="Боттар макс. çапăçусăрах", ultra="Ультра-рикошет", aim_col="Прицел çапăçăвĕсем", show_fps="Мĕнле-ха лыдкалакан",
    player_win="Выляканĕ çĕнтерчĕ", ai_win="ЯИ çĕнтерчĕ",
    again="Тепрех", ok="Лайăх", draw="Тан",
}

T[31] = {
    play="Налхксемс", opt_blood="Вер", opt_particles="Пелькст", opt_ring="Ход ваномо", settings="Настройкат", solo="Вейке", online="Онлайн",
    players="Налхксыцят", borders="Стенат", fruits="Марят", start="Кармавтомс",
    settings_title="Настройкат", language="Кель", reset_lang="Кель пачктамс",
    secret_title="Потавозь меню",
    soft_bots="Боттне макс. а нардыть", ultra="Ультра-рикошет", aim_col="Прицелонь тюшамот", show_fps="Зяро а арсеень",
    player_win="Налхксыця ацирдась", ai_win="ИИ ацирдась",
    again="Вейкеце", ok="Ладя", draw="Тавто",
}

local function tr(key)
    local t = T[settings.lang] or T[1]
    return t[key] or (T[1][key] or key)
end

local function saveSettings()
    local s = tostring(settings.lang)
        .."," .. (settings.blood     and "1" or "0")
        .."," .. (settings.particles and "1" or "0")
        .."," .. (settings.ring      and "1" or "0")
    love.filesystem.write("settings.dat", s)
end

local LOCALE_MAP = {
    ["bs"] = 1,  ["cs"] = 2,  ["de"] = 3,  ["en"] = 4,
    ["es"] = 5,  ["fr"] = 6,  ["hr"] = 7,  ["it"] = 8,
    ["pl"] = 9,  ["rom"]=10,  ["ro"] = 11, ["sk"] = 12,
    ["sl"] = 13, ["sr"] = 14, ["tr"] = 15,
    ["av"] = 16, ["ba"] = 17, ["be"] = 18, ["dar"]=19,
    ["kk"] = 20, ["koi"]=21,  ["lez"]=22,  ["mhr"]=23,
    ["ce"] = 24, ["ru"] = 25, ["sah"]=26,  ["tt"] = 27,
    ["udm"]=28,  ["uk"] = 29, ["cv"] = 30, ["myv"]=31,
}

local function detectSystemLang()
    local locale = os.getenv("LANG") or os.getenv("LANGUAGE") or os.getenv("LC_ALL") or ""
    local code = locale:match("^([a-z]+)") or ""
    if LOCALE_MAP[code] then return LOCALE_MAP[code] end

    local ok, handle = pcall(io.popen, 'powershell -NoProfile -Command "(Get-Culture).TwoLetterISOLanguageName" 2>nul')
    if ok and handle then
        local result = handle:read("*l") or ""
        handle:close()
        local wcode = result:match("^([a-z]+)") or result:lower():match("^([a-z]+)") or ""
        if LOCALE_MAP[wcode] then return LOCALE_MAP[wcode] end
    end

    return 4 -- фоллбэк: English
end

local function loadSettings()
    if love.filesystem.getInfo("settings.dat") then
        local s = love.filesystem.read("settings.dat")
        local parts = {}
        for p in s:gmatch("[^,]+") do parts[#parts+1] = p end
        local n = tonumber(parts[1])
        if n and n >= 1 and n <= #LANGS then settings.lang = n end
        if parts[2] then settings.blood     = parts[2] == "1" end
        if parts[3] then settings.particles = parts[3] == "1" end
        if parts[4] then settings.ring      = parts[4] == "1" end
    else
        settings.lang = detectSystemLang()
    end
end

local function saveSecret()
    local s = (secret.softBots and "1" or "0") .. (secret.ultraRicochet and "1" or "0") .. (secret.aimCollision and "1" or "0") .. (secret.showFps and "1" or "0")
    love.filesystem.write("secret.dat", s)
end

local function loadSecret()
    if love.filesystem.getInfo("secret.dat") then
        local s = love.filesystem.read("secret.dat")
        if s and #s >= 2 then
            secret.softBots      = s:sub(1,1) == "1"
            secret.ultraRicochet = s:sub(2,2) == "1"
            if #s >= 3 then secret.aimCollision = s:sub(3,3) == "1" else secret.aimCollision = true end
            if #s >= 4 then secret.showFps      = s:sub(4,4) == "1" else secret.showFps      = false end
        end
    end
end

local secretTaps   = 0
local secretTapT   = 0
local SECRET_ZONE  = 60   -- размер зоны угла

local solo={players=6, borders=false, fruits=false}
local sliderDrag=false

local function sliderGeom(w,h)
    local trW=300; local trX=w/2-trW/2; local trY=h/2-50
    return trX,trY,trW
end
local function soloKnobX(w,h)
    local trX,_,trW=sliderGeom(w,h)
    return trX+((solo.players-2)/4)*trW
end
local function checkGeom(w,h,idx)
    local size=22
    local trX,_,trW=sliderGeom(w,h)
    return trX+trW-size/2, h/2+30+(idx-1)*66, size
end

local clickSfx=nil
local function playClick()
    if clickSfx then clickSfx:stop();clickSfx:play() end
end

local game = {}

local function inArena(px, py, margin)
    margin = margin or 0
    local ax = ARENA_W/2 - ARENA_RX - margin
    local ay = ARENA_H/2 - ARENA_RX - margin
    local lx = math.abs(px) - ax
    local ly = math.abs(py) - ay
    if lx <= 0 and ly <= 0 then return true end
    local rx = ARENA_RX - margin
    if rx <= 0 or lx > rx or ly > rx then return false end
    return lx*lx + ly*ly <= rx*rx
end

local function spawnFruit()
    if #foodImages == 0 then return end
    local margin = 16 * 4
    local hw = ARENA_W/2 - margin
    local hh = ARENA_H/2 - margin
    local fx, fy
    for _ = 1, 120 do
        local tx = love.math.random(-hw, hw)
        local ty = love.math.random(-hh, hh)
        if inArena(tx, ty, margin) then
            local inWall = false
            for _, w in ipairs(walls) do
                local cx2 = math.max(w.x, math.min(tx, w.x + w.w))
                local cy2 = math.max(w.y, math.min(ty, w.y + w.h))
                local ddx = tx - cx2; local ddy = ty - cy2
                if ddx*ddx + ddy*ddy < (FRUIT_R + 10)^2 then
                    inWall = true; break
                end
            end
            if not inWall then
                local nearChip = false
                for _, chip in ipairs(game.chips) do
                    if chip.alive then
                        local cdx = tx - chip.x
                        local cdy = ty - chip.y
                        if cdx*cdx + cdy*cdy < (CHIP_R + FRUIT_R + 20)^2 then
                            nearChip = true; break
                        end
                    end
                end
                if not nearChip then fx = tx; fy = ty; break end
            end
        end
    end
    if not fx then return end  -- не нашли место — не спавним
    local idx = love.math.random(1, #foodImages)
    fruit = { x=fx, y=fy, img=foodImages[idx], imgIdx=idx }
end

local function checkFruitEaten()
    if not fruit then return end
    for _, c in ipairs(game.chips) do
        if c.alive then
            local dx = c.x - fruit.x
            local dy = c.y - fruit.y
            if dx*dx + dy*dy < (CHIP_R + FRUIT_R)^2 then
                c.hp = math.min(c.hp + 1, 3)
                spawnJuice(fruit.x, fruit.y, JUICE_COLORS[fruit.imgIdx or 1] or "#f1f2bf")
                fruit = nil
                return
            end
        end
    end
end

local function chipFellOff(chip)
    local hw = ARENA_W/2
    local hh = ARENA_H/2
    return math.abs(chip.x) > hw or math.abs(chip.y) > hh
end

local function bounceArena(chip)
    local px, py = chip.x, chip.y
    local r  = CHIP_R
    local hw = ARENA_W/2 - r
    local hh = ARENA_H/2 - r
    local rx = ARENA_RX

    local inCornerX = math.abs(px) > (ARENA_W/2 - rx)
    local inCornerY = math.abs(py) > (ARENA_H/2 - rx)

    if not inCornerY then
        local bounce = secret.ultraRicochet and 2.1 or 0.7
        if px > hw  then chip.x = hw;  chip.vx = -math.abs(chip.vx)*bounce end
        if px < -hw then chip.x = -hw; chip.vx =  math.abs(chip.vx)*bounce end
    end
    if not inCornerX then
        local bounce = secret.ultraRicochet and 2.1 or 0.7
        if py > hh  then chip.y = hh;  chip.vy = -math.abs(chip.vy)*bounce end
        if py < -hh then chip.y = -hh; chip.vy =  math.abs(chip.vy)*bounce end
    end

    if inCornerX and inCornerY then
        local signX = px > 0 and 1 or -1
        local signY = py > 0 and 1 or -1
        local cornerX = signX * (ARENA_W/2 - rx)
        local cornerY = signY * (ARENA_H/2 - rx)
        local dx = px - cornerX
        local dy = py - cornerY
        local d  = math.sqrt(dx*dx + dy*dy)
        local limit = rx - r  -- максимальное расстояние центра чипа от центра скругления
        if d > limit and d > 0.001 then
            local nx = dx/d; local ny = dy/d
            chip.x = cornerX + nx * limit
            chip.y = cornerY + ny * limit
            local dot = chip.vx*nx + chip.vy*ny
            if dot > 0 then
                local bounce = secret.ultraRicochet and 2.1 or 0.7
                chip.vx = chip.vx - 2*dot*nx * bounce
                chip.vy = chip.vy - 2*dot*ny * bounce
            end
        end
    end
end


local function rectsOverlap(ax,ay,aw,ah, bx,by,bw,bh, margin)
    margin = margin or 0
    return ax-margin < bx+bw+margin and ax+aw+margin > bx-margin
       and ay-margin < by+bh+margin and ay+ah+margin > by-margin
end

local function generateWalls()
    walls = {}
    if not solo.borders then return end   -- приграды отключены — стен нет
    local edgeMargin = 62          -- дистанция от бездны
    local halfW  = ARENA_W/2 - edgeMargin
    local halfH  = ARENA_H/2 - edgeMargin

    local attempts = 0
    local placed   = 0
    while placed < WALL_COUNT and attempts < 600 do
        attempts = attempts + 1

        local horiz = love.math.random(0,1) == 0
        local len   = love.math.random(WALL_MIN_LEN, WALL_MAX_LEN)
        local ww, wh
        if horiz then
            ww = len;        wh = WALL_THICK
        else
            ww = WALL_THICK; wh = len
        end

        local x = love.math.random(-halfW, halfW - ww)
        local y = love.math.random(-halfH, halfH - wh)

        if x < -halfW or x+ww > halfW then goto wallNext end
        if y < -halfH or y+wh > halfH then goto wallNext end

        do
        local spawnR = math.min(ARENA_W, ARENA_H) * 0.38
        local bad = false
        local n = solo.players
        for i = 1, n do
            local angle = (i-1)/n * math.pi*2
            local sx = math.cos(angle)*spawnR
            local sy = math.sin(angle)*spawnR
            local cx = math.max(x, math.min(sx, x+ww))
            local cy = math.max(y, math.min(sy, y+wh))
            if dist(sx,sy,cx,cy) < CHIP_R*6 then
                bad = true; break
            end
        end
        if bad then goto wallNext end

        for _,w2 in ipairs(walls) do
            if rectsOverlap(x,y,ww,wh, w2.x,w2.y,w2.w,w2.h, 70) then
                bad = true; break
            end
        end
        if bad then goto wallNext end

        walls[#walls+1] = { x=x, y=y, w=ww, h=wh }
        placed = placed + 1
        end

        ::wallNext::
    end
end

local function bounceWalls(chip)
    local r = CHIP_R
    for _, w in ipairs(walls) do
        local cx = math.max(w.x, math.min(chip.x, w.x + w.w))
        local cy = math.max(w.y, math.min(chip.y, w.y + w.h))
        local dx = chip.x - cx
        local dy = chip.y - cy
        local d  = math.sqrt(dx*dx + dy*dy)
        if d < r and d > 0.001 then
            local nx = dx/d; local ny = dy/d
            chip.x = cx + nx * r
            chip.y = cy + ny * r
            local dot = chip.vx*nx + chip.vy*ny
            if dot < 0 then
                local bounce = secret.ultraRicochet and 2.1 or 0.7
                chip.vx = chip.vx - 2*dot*nx * bounce
                chip.vy = chip.vy - 2*dot*ny * bounce
            end
        end
    end
end

local function drawWalls()
    for _, w in ipairs(walls) do
        love.graphics.setColor(WALL_COLOR[1], WALL_COLOR[2], WALL_COLOR[3], 1)
        love.graphics.rectangle("fill", w.x, w.y, w.w, w.h, WALL_RX, WALL_RX)
        love.graphics.setColor(0, 0, 0, 0.35)
        love.graphics.setLineWidth(2.2)
        love.graphics.rectangle("line", w.x, w.y, w.w, w.h, WALL_RX, WALL_RX)
    end
end

local function initGame()
    particles = {}
    blood     = {}
    walls     = {}
    fruit            = nil
    fruitTurnCounter = 0
    bloodDrops       = {}
    game = {
        chips      = {},
        turn       = 1,      -- индекс текущего чипа
        moving     = false,  -- летит ли чип
        botTimer   = 0,
        botThinking= false,
        turnDelay  = 0,      -- пауза перед следующим ходом
        sling      = { active=false, mx=0, my=0 },
        camX       = 0, camY = 0,
        playerIdx  = 1,      -- всегда первый чип
        winner     = nil,
        winDelay   = nil,    -- задержка перед экраном победы (секунды)
        hitCooldown= {},     -- кулдаун урона между парами чипов
        ringAngle  = 0,      -- угол вращения дуг вокруг активной фишки
        ringAlpha  = 1,      -- плавная прозрачность дуг (0..1)
        mouseClicked = false,
    }

    local n = solo.players
    game._chipColors = shuffledColors(n)
    local r_spawn = math.min(ARENA_W, ARENA_H) * 0.38
    local angleOffset = love.math.random() * math.pi * 2  -- рандомный поворот кольца

    generateWalls()

    for i = 1, n do
        local angle = angleOffset + (i-1) / n * math.pi * 2
        local sx = math.cos(angle) * r_spawn
        local sy = math.sin(angle) * r_spawn

        for _=1, 8 do
            local pushed = false
            for _, w in ipairs(walls) do
                local cx2 = math.max(w.x, math.min(sx, w.x + w.w))
                local cy2 = math.max(w.y, math.min(sy, w.y + w.h))
                local ddx = sx - cx2
                local ddy = sy - cy2
                local dd  = math.sqrt(ddx*ddx + ddy*ddy)
                if dd < CHIP_R + 4 then
                    if dd < 0.01 then ddx = 1; ddy = 0; dd = 1 end
                    local push = (CHIP_R + 5 - dd)
                    sx = sx + (ddx/dd) * push
                    sy = sy + (ddy/dd) * push
                    pushed = true
                end
            end
            if not pushed then break end
        end

        game.chips[i] = {
            x    = sx, y = sy,
            vx   = 0,  vy = 0,
            hp   = 3,
            alive= true,
            color= game._chipColors[i],
            isBot= (i ~= game.playerIdx),
        }
    end
end

local TURN_PAUSE = 0.35  -- пауза между ходами в секундах

local function nextTurn()
    if game.winner then return end
    local n = #game.chips
    local start = game.turn
    for _, c in ipairs(game.chips) do
        c.aimShow = false
        c.aimVx = nil
        c.aimVy = nil
    end
    for i = 1, n do
        local idx = (start - 1 + i) % n + 1
        if game.chips[idx].alive then
            game.turn = idx
            game.moving = false
            game.botThinking = false
            game.turnDelay = TURN_PAUSE
            game._nextIsBot = game.chips[idx].isBot
            return
        end
    end
end

local function checkWinner()
    local alive = {}
    for _,c in ipairs(game.chips) do
        if c.alive then alive[#alive+1] = c end
    end
    local playerChip = game.chips[game.playerIdx]
    if playerChip and not playerChip.alive and not game.winner then
        game.winner = "bot"
        return true
    end
    if #alive == 1 then
        game.winner = alive[1].isBot and "bot" or "player"
        return true
    end
    if #alive == 0 then game.winner = "draw"; return true end
    return false
end

local function simulateChip(x, y, vx, vy, steps)
    for _ = 1, steps do
        x = x + vx; y = y + vy
        vx = vx * FRICTION; vy = vy * FRICTION
        local hw = ARENA_W/2 - CHIP_R
        local hh = ARENA_H/2 - CHIP_R
        if x > hw then x = hw; vx = -math.abs(vx)*0.7 end
        if x < -hw then x = -hw; vx = math.abs(vx)*0.7 end
        if y > hh then y = hh; vy = -math.abs(vy)*0.7 end
        if y < -hh then y = -hh; vy = math.abs(vy)*0.7 end
    end
    return x, y
end


local function calcLaunchVelocity(chip, tx, ty)
    local dx = tx - chip.x; local dy = ty - chip.y
    local d  = math.sqrt(dx*dx + dy*dy)
    if d < 1 then return 0, 0 end
    local ndx = dx/d; local ndy = dy/d

    local lo, hi = 0.0, 60.0
    for _=1, 18 do
        local mid = (lo+hi)*0.5
        local px, py = simulateChip(chip.x, chip.y, ndx*mid, ndy*mid, 200)
        local arrived  = dist(chip.x, chip.y, px, py)
        local target_d = dist(chip.x, chip.y, tx, ty)
        if arrived > target_d then hi = mid else lo = mid end
    end
    local speed = (lo+hi)*0.5
    return ndx*speed, ndy*speed
end

local function edgeDist(x, y)
    return math.min(ARENA_W/2 - math.abs(x), ARENA_H/2 - math.abs(y))
end

local function simCollision(cx, cy, cvx, cvy, tx, ty, tvx, tvy, steps)
    local x1, y1 = cx, cy
    local x2, y2 = tx, ty
    local vx1, vy1 = cvx, cvy
    local vx2, vy2 = tvx, tvy
    local hit = false
    local impVx1, impVy1 = vx1, vy1
    local impVx2, impVy2 = vx2, vy2

    for _ = 1, steps do
        x1 = x1 + vx1; y1 = y1 + vy1
        x2 = x2 + vx2; y2 = y2 + vy2
        vx1 = vx1 * FRICTION; vy1 = vy1 * FRICTION
        vx2 = vx2 * FRICTION; vy2 = vy2 * FRICTION

        local ddx = x2-x1; local ddy = y2-y1
        local dd = math.sqrt(ddx*ddx + ddy*ddy)
        if not hit and dd < CHIP_R*2 then
            hit = true
            local nx2, ny2 = ddx/dd, ddy/dd
            local relVx = vx1 - vx2
            local relVy = vy1 - vy2
            local dot2 = relVx*nx2 + relVy*ny2
            if dot2 > 0 then
                local imp = dot2 * 0.9
                impVx1 = vx1 - imp*nx2
                impVy1 = vy1 - imp*ny2
                impVx2 = vx2 + imp*nx2
                impVy2 = vy2 + imp*ny2
                vx1, vy1 = impVx1, impVy1
                vx2, vy2 = impVx2, impVy2
            end
        end

        local hw = ARENA_W/2 - CHIP_R; local hh = ARENA_H/2 - CHIP_R
        if x1 > hw then x1=hw; vx1=-math.abs(vx1)*0.7 end
        if x1 <-hw then x1=-hw; vx1= math.abs(vx1)*0.7 end
        if y1 > hh then y1=hh; vy1=-math.abs(vy1)*0.7 end
        if y1 <-hh then y1=-hh; vy1= math.abs(vy1)*0.7 end
        if x2 > hw then x2=hw; vx2=-math.abs(vx2)*0.7 end
        if x2 <-hw then x2=-hw; vx2= math.abs(vx2)*0.7 end
        if y2 > hh then y2=hh; vy2=-math.abs(vy2)*0.7 end
        if y2 <-hh then y2=-hh; vy2= math.abs(vy2)*0.7 end
    end
    return x1, y1, x2, y2, hit
end

local function scoreShot(chip, target, angleOffset, distFrac, threatWeight)
    local dx = target.x - chip.x
    local dy = target.y - chip.y
    local d  = math.sqrt(dx*dx + dy*dy)
    if d < 0.01 then return -9999, 0, 0 end

    local MAX_REACH = 17 * 26
    local aimAngle  = math.atan2(dy, dx) + angleOffset
    local aimDist   = MAX_REACH * distFrac

    local ptX = chip.x + math.cos(aimAngle) * aimDist
    local ptY = chip.y + math.sin(aimAngle) * aimDist

    local shotVx, shotVy = calcLaunchVelocity(chip, ptX, ptY)

    local selfPx, selfPy, tgtPxAfter, tgtPyAfter, didHit = simCollision(
        chip.x, chip.y, shotVx, shotVy,
        target.x, target.y, target.vx or 0, target.vy or 0,
        80
    )

    if not inArena(selfPx, selfPy) then return -9999, 0, 0 end

    local score = 0

    if not didHit then score = score - 300 end

    local tgtEdgeAfter  = edgeDist(tgtPxAfter, tgtPyAfter)
    local tgtEdgeBefore = edgeDist(target.x, target.y)
    score = score + (630 - tgtEdgeAfter) * 2.2 * threatWeight

    if tgtEdgeBefore < 200 then
        score = score + (200 - tgtEdgeBefore) * 2.0 * threatWeight
    end

    local selfEdgeAfter = edgeDist(selfPx, selfPy)
    if selfEdgeAfter < 120 then
        score = score - (120 - selfEdgeAfter) * 3.5
    elseif selfEdgeAfter < 220 then
        score = score - (220 - selfEdgeAfter) * 1.0
    end

    if distFrac < 0.45 and tgtEdgeBefore > 280 then score = score - 80 end
    score = score - math.abs(angleOffset) * 15

    return score, shotVx, shotVy
end


local function segmentHitsWall(ax, ay, bx, by)
    for _, w in ipairs(walls) do
        local dx = bx - ax; local dy = by - ay
        local p = { -dx, dx, -dy, dy }
        local q = { ax - w.x, w.x + w.w - ax, ay - w.y, w.y + w.h - ay }
        local t0, t1 = 0.0, 1.0
        local hit = true
        for k = 1, 4 do
            if p[k] == 0 then
                if q[k] < 0 then hit = false; break end
            elseif p[k] < 0 then
                t0 = math.max(t0, q[k]/p[k])
            else
                t1 = math.min(t1, q[k]/p[k])
            end
        end
        if hit and t0 < t1 then return true end
    end
    return false
end

local function findWaypoint(sx, sy, tx, ty)
    if not segmentHitsWall(sx, sy, tx, ty) then
        return nil  -- прямой путь свободен
    end

    local bestWP = nil
    local bestDist = math.huge

    for _, w in ipairs(walls) do
        local margin = CHIP_R + 8
        local corners = {
            { w.x - margin,        w.y - margin },
            { w.x + w.w + margin,  w.y - margin },
            { w.x - margin,        w.y + w.h + margin },
            { w.x + w.w + margin,  w.y + w.h + margin },
        }
        for _, c in ipairs(corners) do
            local cx, cy = c[1], c[2]
            if inArena(cx, cy) then
                if not segmentHitsWall(sx, sy, cx, cy) and not segmentHitsWall(cx, cy, tx, ty) then
                    local d = dist(sx, sy, cx, cy) + dist(cx, cy, tx, ty)
                    if d < bestDist then
                        bestDist = d
                        bestWP = { x = cx, y = cy }
                    end
                end
            end
        end
    end

    if not bestWP then
        for _, w in ipairs(walls) do
            local margin = CHIP_R + 8
            local mids = {
                { w.x + w.w/2,         w.y - margin },
                { w.x + w.w/2,         w.y + w.h + margin },
                { w.x - margin,        w.y + w.h/2 },
                { w.x + w.w + margin,  w.y + w.h/2 },
            }
            for _, c in ipairs(mids) do
                local cx, cy = c[1], c[2]
                if inArena(cx, cy) then
                    if not segmentHitsWall(sx, sy, cx, cy) and not segmentHitsWall(cx, cy, tx, ty) then
                        local d = dist(sx, sy, cx, cy) + dist(cx, cy, tx, ty)
                        if d < bestDist then
                            bestDist = d
                            bestWP = { x = cx, y = cy }
                        end
                    end
                end
            end
        end
    end

    return bestWP
end

local function botShoot(chip)
    local targets = {}
    for _, c in ipairs(game.chips) do
        if c ~= chip and c.alive then targets[#targets+1] = c end
    end
    if #targets == 0 then return end

    local selfEdge     = edgeDist(chip.x, chip.y)
    local iAmDangerous = selfEdge < 150
    local lastAttacker = chip.lastAttacker

    local weights = {}
    for _, t in ipairs(targets) do
        local w = 1.0
        if lastAttacker and t == lastAttacker then w = w + 1.8 end
        local tEdge = edgeDist(t.x, t.y)
        if tEdge < 150 then w = w + (150 - tEdge) / 75 end
        local dd = dist(chip.x, chip.y, t.x, t.y)
        if dd < 180 then w = w + (180 - dd) / 120 end
        if t.hp == 1 then w = w + 0.8 end
        weights[t] = w
    end

    local distOptions
    if iAmDangerous then
        distOptions = { 0.30, 0.42, 0.55 }
    else
        distOptions = { 0.45, 0.60, 0.75, 0.92 }
    end

    local angleSteps = { -0.45, -0.26, -0.10, 0, 0.10, 0.26, 0.45 }

    local bestScore = -math.huge
    local bestVx, bestVy = 0, 0

    for _, target in ipairs(targets) do
        local tw = weights[target] or 1.0

        local waypoint = nil
        if #walls > 0 then
            waypoint = findWaypoint(chip.x, chip.y, target.x, target.y)
        end

        if waypoint then
            local fakeTarget = { x = waypoint.x, y = waypoint.y, vx = 0, vy = 0, hp = 1 }
            for _, aOff in ipairs(angleSteps) do
                for _, dfrac in ipairs(distOptions) do
                    local s, vx, vy = scoreShot(chip, fakeTarget, aOff, dfrac, tw * 0.8)
                    s = s + 150  -- бонус за попытку обойти стену
                    if s > bestScore then
                        bestScore = s
                        bestVx = vx; bestVy = vy
                    end
                end
            end
            for _, aOff in ipairs(angleSteps) do
                for _, dfrac in ipairs(distOptions) do
                    local s, vx, vy = scoreShot(chip, target, aOff, dfrac, tw)
                    if s > bestScore then
                        bestScore = s
                        bestVx = vx; bestVy = vy
                    end
                end
            end
        else
            for _, aOff in ipairs(angleSteps) do
                for _, dfrac in ipairs(distOptions) do
                    local s, vx, vy = scoreShot(chip, target, aOff, dfrac, tw)
                    if s > bestScore then
                        bestScore = s
                        bestVx = vx; bestVy = vy
                    end
                end
            end
        end
    end

    if bestScore < -200 then
        local cx2 = -chip.x; local cy2 = -chip.y
        local cn = math.sqrt(cx2*cx2 + cy2*cy2)
        if cn > 0.01 then
            bestVx, bestVy = calcLaunchVelocity(chip, chip.x + (cx2/cn)*300, chip.y + (cy2/cn)*300)
        end
    end

    chip.lastAttacker = nil

    local jitter = 0.03
    bestVx = bestVx * (1 + (love.math.random()-0.5)*jitter)
    bestVy = bestVy * (1 + (love.math.random()-0.5)*jitter)

    if secret.softBots then
        local spd = math.sqrt(bestVx*bestVx + bestVy*bestVy)
        local maxSpd = 28  -- ограничиваем максимальный удар
        if spd > maxSpd then
            bestVx = bestVx / spd * maxSpd
            bestVy = bestVy / spd * maxSpd
        end
    end

    chip.launchVx = bestVx
    chip.launchVy = bestVy
    chip.launchT  = 0
    chip.vx = 0; chip.vy = 0
    game.moving      = true
    game.botThinking = false
end

local function updateGame(dt)
    if game.winner and not game.winDelay then return end

    for k,v in pairs(game.hitCooldown) do
        game.hitCooldown[k] = v - dt
        if game.hitCooldown[k] <= 0 then
            game.hitCooldown[k] = nil
        end
    end

    updateParticles(dt)
    updateBloodDrops(dt)

    game.ringAngle = game.ringAngle + dt * 0.7

    local hideRing = game.mouseClicked or (game.sling and game.sling.active)
    if hideRing then
        game.ringAlpha = math.max(0, game.ringAlpha - dt * 6)
    else
        game.ringAlpha = math.min(1, game.ringAlpha + dt * 4)
    end

    local anyMoving = false
    local anyLiveMoving = false  -- только живые чипы в движении

    for _,c in ipairs(game.chips) do
        if not c.alive and c.deathT and c.deathT < 1 then
            c.deathT = math.min(1, c.deathT + dt / 0.55)
            if c.deathVx then
                c.deathX = c.deathX + c.deathVx * dt * 60
                c.deathY = c.deathY + c.deathVy * dt * 60
                c.deathVx = c.deathVx * 0.88
                c.deathVy = c.deathVy * 0.88
            end
            anyMoving = true  -- анимация ещё идёт (для рендера), но не блокирует ходы
        end
    end

    for _,c in ipairs(game.chips) do
        if c.alive and c.launchT and c.launchT < 1 then
            c.launchT = math.min(1, c.launchT + dt / 0.12)
            local ease = c.launchT * c.launchT  -- ease-in
            c.vx = c.launchVx * ease
            c.vy = c.launchVy * ease
            if c.launchT >= 1 then c.launchT = nil; c.launchVx = nil; c.launchVy = nil end
        end
    end

    for _,c in ipairs(game.chips) do
        if not c.alive then goto continue end
        local speed = math.sqrt(c.vx*c.vx + c.vy*c.vy)
        if speed > MIN_SPEED then
            anyMoving = true
            anyLiveMoving = true
            local steps = math.max(1, math.ceil(speed / 12))
            local subDt = dt / steps
            for _=1,steps do
                c.x = c.x + c.vx * subDt * 60
                c.y = c.y + c.vy * subDt * 60
                c.vx = c.vx * (FRICTION ^ (subDt * 60))
                c.vy = c.vy * (FRICTION ^ (subDt * 60))

                bounceWalls(c)
                for _, other in ipairs(game.chips) do
                    if other ~= c and other.alive then
                        local cdx = other.x - c.x
                        local cdy = other.y - c.y
                        local cd = math.sqrt(cdx*cdx + cdy*cdy)
                        if cd < CHIP_R*2 and cd > 0.01 then
                            local cnx, cny = cdx/cd, cdy/cd
                            local overlap2 = CHIP_R*2 - cd
                            c.x = c.x - cnx*overlap2*0.5
                            c.y = c.y - cny*overlap2*0.5
                            other.x = other.x + cnx*overlap2*0.5
                            other.y = other.y + cny*overlap2*0.5
                        end
                    end
                end
                if not inArena(c.x, c.y, -CHIP_R * 3) then
                    c.alive = false
                    c.deathX = c.x
                    c.deathY = c.y
                    c.deathT = 0
                    c.deathVx = c.vx * 0.85
                    c.deathVy = c.vy * 0.85
                    c.vx, c.vy = 0, 0
                    break
                end
            end
        else
            c.vx, c.vy = 0, 0
        end
        ::continue::
    end

    local chips = game.chips
    for i = 1, #chips do
        for j = i+1, #chips do
            local a,b = chips[i], chips[j]
            if a.alive and b.alive then
                local dx = b.x-a.x; local dy = b.y-a.y
                local d = math.sqrt(dx*dx+dy*dy)
                if d < CHIP_R*2 and d > 0.01 then
                    local overlap = CHIP_R*2 - d
                    local nx,ny = dx/d, dy/d
                    a.x = a.x - nx*overlap*0.5
                    a.y = a.y - ny*overlap*0.5
                    b.x = b.x + nx*overlap*0.5
                    b.y = b.y + ny*overlap*0.5

                    local relVx = a.vx - b.vx
                    local relVy = a.vy - b.vy
                    local dot = relVx*nx + relVy*ny
                    if dot > 0 then
                        local speedA_before = math.sqrt(a.vx*a.vx + a.vy*a.vy)
                        local speedB_before = math.sqrt(b.vx*b.vx + b.vy*b.vy)

                        local imp = secret.ultraRicochet and (dot * 2.4) or (dot * 0.9)
                        a.vx = a.vx - imp*nx; a.vy = a.vy - imp*ny
                        b.vx = b.vx + imp*nx; b.vy = b.vy + imp*ny

                        local dmgSpeed = math.sqrt(relVx*relVx+relVy*relVy)
                        local pairKey = i..":"..j
                        local cooldownOk = not game.hitCooldown[pairKey]
                        if dmgSpeed > 4 and cooldownOk then
                            game.hitCooldown[pairKey] = 0.4  -- секунд кулдауна
                            local impactSpeed = 300 + math.min(dmgSpeed * 15, 500)
                            local bloodT  = math.min(dmgSpeed / 55, 1.0)  -- 0=слабо, 1=максимум
                            local bSpread = CHIP_R * (1.2 + bloodT * 3.5)    -- радиус брызг
                            local bBlob   = CHIP_R * (0.35 + bloodT * 1.4)   -- размер пятна
                            local pCount  = math.floor(3 + bloodT * 8)        -- кол-во частиц

                            if speedA_before >= speedB_before then
                                if b.isBot then b.lastAttacker = a end
                                b.hp = b.hp - 1
                                if b.hp <= 0 then
                                    b.alive=false
                                    b.deathX=b.x; b.deathY=b.y; b.deathT=0
                                    b.deathVx=b.vx*0.85; b.deathVy=b.vy*0.85
                                    b.vx=0; b.vy=0
                                    if settings.particles then spawnParticles(b.deathX, b.deathY, pCount+8, 2, 5, impactSpeed * 1.4, 3.0) end
                                    if settings.blood then spawnBlood(b.deathX, b.deathY, bSpread * 1.5, bBlob * 1.5, bloodT) end
                                else
                                    if settings.particles then spawnParticles(b.x, b.y, pCount, 1.5, 3.5, impactSpeed, 3.0) end
                                    if settings.blood then spawnBlood(b.x, b.y, bSpread, bBlob, bloodT) end
                                end
                            else
                                if a.isBot then a.lastAttacker = b end
                                a.hp = a.hp - 1
                                if a.hp <= 0 then
                                    a.alive=false
                                    a.deathX=a.x; a.deathY=a.y; a.deathT=0
                                    a.deathVx=a.vx*0.85; a.deathVy=a.vy*0.85
                                    a.vx=0; a.vy=0
                                    if settings.particles then spawnParticles(a.deathX, a.deathY, pCount+8, 2, 5, impactSpeed * 1.4, 3.0) end
                                    if settings.blood then spawnBlood(a.deathX, a.deathY, bSpread * 1.5, bBlob * 1.5, bloodT) end
                                else
                                    if settings.particles then spawnParticles(a.x, a.y, pCount, 1.5, 3.5, impactSpeed, 3.0) end
                                    if settings.blood then spawnBlood(a.x, a.y, bSpread, bBlob, bloodT) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    checkFruitEaten()
    checkWinner()

    if game.winDelay then
        game.winDelay = game.winDelay - dt
        if game.winDelay <= 0 then
            game.winDelay = nil
            goTo("result")
            return
        end
        return
    end
    if game.winner and not game.winDelay then
        game.winDelay = 2.0
        return
    end

    local curChip = game.chips[game.turn]
    if curChip and not curChip.alive and not game.moving then
        nextTurn()
    end

    if game.turnDelay and game.turnDelay > 0 then
        game.turnDelay = game.turnDelay - dt
        if game.turnDelay <= 0 then
            game.turnDelay = 0
            game.botThinking = game._nextIsBot or false
            game.botTimer = BOT_THINK
        end
    end

    if game.botThinking and not anyLiveMoving and (not game.turnDelay or game.turnDelay <= 0) then
        game.botTimer = game.botTimer - dt
        if game.botTimer <= 0 then
            local c = game.chips[game.turn]
            if c and c.alive then botShoot(c) end
        end
    end

    if game.moving and not anyLiveMoving then
        fruitTurnCounter = fruitTurnCounter + 1
        if fruitTurnCounter >= 2 and not fruit then
            fruitTurnCounter = 0
            spawnFruit()
        end
        nextTurn()
    end

    local pc = game.chips[game.playerIdx]
    if pc and pc.alive then
        game.camX = pc.x
        game.camY = pc.y
    else
        local cur = game.chips[game.turn]
        if cur and cur.alive then
            game.camX = cur.x
            game.camY = cur.y
        end
    end
end

local function drawArena()
    local w,h = ARENA_W, ARENA_H
    local rx   = ARENA_RX

    setCol("#8fc0c9")
    love.graphics.rectangle("fill", -w/2-300, -h/2-300, w+600, h+600, 0, 0)

    setCol("#c5d3d6")
    love.graphics.rectangle("fill", -w/2, -h/2, w, h, rx, rx)

    love.graphics.setColor(0,0,0,0.35)
    love.graphics.setLineWidth(2.2)
    love.graphics.rectangle("line", -w/2, -h/2, w, h, rx, rx)
end

local function drawChips()
    for i,c in ipairs(game.chips) do
        if not c.alive then
            if c.deathT and c.deathT < 1 then
                local t = c.deathT
                local s = (1 - t) * (1 - t * 0.4)   -- плавное уменьшение
                local alpha = math.max(0, 1 - t * 1.1)
                if s > 0.02 then
                    love.graphics.push()
                    love.graphics.translate(c.deathX, c.deathY)
                    love.graphics.scale(s, s)
                    local cr,cg,cb = hex(c.color)
                    love.graphics.setColor(cr, cg, cb, alpha)
                    love.graphics.circle("fill", 0, 0, CHIP_R)
                    love.graphics.setColor(0, 0, 0, 0.35 * alpha)
                    love.graphics.setLineWidth(1.8)
                    love.graphics.circle("line", 0, 0, CHIP_R)
                    love.graphics.pop()
                end
            end
            goto skip
        end
        setCol(c.color)
        love.graphics.circle("fill", c.x, c.y, CHIP_R)
        love.graphics.setColor(0,0,0,0.35)
        love.graphics.setLineWidth(1.8)
        love.graphics.circle("line", c.x, c.y, CHIP_R)

        if i == game.turn and not c.isBot and not game.moving and not game.botThinking and not (game.turnDelay and game.turnDelay > 0) then
            local a = game.ringAlpha or 0
            if a > 0.01 then
                local ringR   = CHIP_R + 6
                local arcSpan = math.pi / 4.8      -- чуть короче (~37°)
                local period  = 2 * math.pi / 3
                love.graphics.setColor(0, 0, 0, 0.52 * a)
                love.graphics.setLineWidth(1.9)
                for k = 0, 2 do
                    local startA = game.ringAngle + k * period
                    love.graphics.arc("line", "open", c.x, c.y, ringR, startA, startA + arcSpan, 16)
                end
            end
        end
        ::skip::
    end
end

local function calcAim(chip, mx, my, camX, camY, sw, sh)
    local cx = sw/2 + (chip.x - camX)
    local cy = sh/2 + (chip.y - camY)
    local dx = cx - mx; local dy = cy - my
    local d  = math.sqrt(dx*dx+dy*dy)
    if d < 5 then return nil end
    local nx = dx/d; local ny = dy/d

    local t = math.min(d, SLING_MAX) / SLING_MAX
    local numDots = math.max(1, math.floor(t * 18))
    local step    = 26

    local ex = cx + nx * step * numDots
    local ey = cy + ny * step * numDots
    local worldTargetX = chip.x + (ex - cx)
    local worldTargetY = chip.y + (ey - cy)

    local dirX = worldTargetX - chip.x
    local dirY = worldTargetY - chip.y
    local dd   = math.sqrt(dirX*dirX + dirY*dirY)
    if dd < 1 then return nil end
    local ndx = dirX/dd; local ndy = dirY/dd

    local lo, hi = 0.0, 60.0  -- диапазон начальной скорости в пикс/фрейм
    for _=1, 18 do
        local mid = (lo+hi)*0.5
        local px, py = simulateChip(chip.x, chip.y, ndx*mid, ndy*mid, 200)
        local arrived = dist(px, py, worldTargetX, worldTargetY)
        local overshot = dist(chip.x, chip.y, px, py) > dist(chip.x, chip.y, worldTargetX, worldTargetY)
        if overshot then hi = mid else lo = mid end
    end
    local speed = (lo+hi)*0.5
    if speed < MIN_SPEED + 1 then speed = MIN_SPEED + 1 end

    return {
        numDots    = numDots,
        step       = step,
        nx         = nx, ny = ny,
        cx         = cx, cy = cy,
        vx         = ndx * speed,
        vy         = ndy * speed,
        worldX     = worldTargetX,
        worldY     = worldTargetY,
    }
end

local function drawAimDotsFromVelocity(chip, camX, camY, sw, sh)
    if not chip.aimVx then return end
    local speed = math.sqrt(chip.aimVx*chip.aimVx + chip.aimVy*chip.aimVy)
    if speed < 0.1 then return end

    local x, y, vx, vy = chip.x, chip.y, chip.aimVx, chip.aimVy
    local dotInterval = 8   -- каждые 8 физ. шагов — точка
    local maxDots     = 18
    local dotCount    = 0
    local offX = sw/2 - camX
    local offY = sh/2 - camY

    local cr, cg, cb = hex(chip.color)

    for step = 1, 200 do
        x = x + vx; y = y + vy
        vx = vx * FRICTION; vy = vy * FRICTION
        if step % dotInterval == 0 then
            dotCount = dotCount + 1
            local alpha = 1 - (dotCount / maxDots) * 0.7
            love.graphics.setColor(cr, cg, cb, alpha)
            love.graphics.circle("fill", x + offX, y + offY, 3)
            love.graphics.setColor(0, 0, 0, alpha * 0.4)
            love.graphics.setLineWidth(1)
            love.graphics.circle("line", x + offX, y + offY, 3)
            if dotCount >= maxDots then break end
        end
        if math.sqrt(vx*vx+vy*vy) < MIN_SPEED then break end
    end
end

local function drawAimDots(chip, mx, my, camX, camY, sw, sh)
    local aim = calcAim(chip, mx, my, camX, camY, sw, sh)
    if not aim then return end
    local dotR = 3
    for i = 1, aim.numDots do
        local ex = aim.cx + aim.nx * aim.step * i
        local ey = aim.cy + aim.ny * aim.step * i
        local wx = ex - sw/2 + camX
        local wy = ey - sh/2 + camY
        if secret.aimCollision then
            if fruit then
                local fdx = wx - fruit.x
                local fdy = wy - fruit.y
                if fdx*fdx + fdy*fdy < (CHIP_R + FRUIT_R)^2 then break end
            end
            local hitChip = false
            for _, other in ipairs(game.chips) do
                if other ~= chip and other.alive then
                    local cdx = wx - other.x
                    local cdy = wy - other.y
                    if cdx*cdx + cdy*cdy < (CHIP_R * 2)^2 then
                        hitChip = true; break
                    end
                end
            end
            if hitChip then break end
            local hitWall = false
            for _, w in ipairs(walls) do
                local cx2 = math.max(w.x, math.min(wx, w.x + w.w))
                local cy2 = math.max(w.y, math.min(wy, w.y + w.h))
                local wdx = wx - cx2; local wdy = wy - cy2
                if wdx*wdx + wdy*wdy < CHIP_R*CHIP_R then
                    hitWall = true; break
                end
            end
            if hitWall then break end
        end
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.circle("fill", ex, ey, dotR)
    end
end

local hpFont  = nil  -- инициализируется в love.load
local fpsFont = nil  -- маленький шрифт для счётчика FPS

local function drawHUD(sw, sh)
    local pc = game.chips[game.playerIdx]
    if not pc or not pc.alive then return end

    local cx2 = 50; local cy2 = sh - 50; local hr = 26
    love.graphics.setColor(0,0,0,1)
    love.graphics.setLineWidth(1.2)
    love.graphics.circle("line", cx2, cy2, hr)
    love.graphics.setColor(0,0,0,1)
    if not hpFont then hpFont = love.graphics.newFont("Rubik-VariableFont_wght.ttf", 22) end
    love.graphics.setFont(hpFont)
    local hpStr = tostring(pc.hp)
    local hw = hpFont:getWidth(hpStr)
    love.graphics.print(hpStr, math.floor(cx2 - hw/2), math.floor(cy2 - hpFont:getHeight()/2))
end

local function drawMain(w,h,a)
    setCol("#111111",a)
    love.graphics.setFont(titleFont)
    local tw = titleFont:getWidth("Tōlpanata")+2
    local tx = math.floor(w/2-tw/2); local ty = math.floor(h/2-65)
    love.graphics.print("Tōlpanata", tx,   ty)
    love.graphics.print("Tōlpanata", tx+1, ty)
    love.graphics.print("Tōlpanata", tx+2, ty)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("play"),w/2,h/2+40)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("settings"),w/2,h/2+95)
end

local function drawMode(w,h,a)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("solo"),  w/2,h/2-35)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("online"),w/2,h/2+30)
end

local function drawSolo(w,h,a)
    local trX,trY,trW = sliderGeom(w,h)
    local r2,g2,b2 = hex("#111111")

    setCol("#111111",a)
    printBoldCenter(lblFont,tr("players").."  "..solo.players, w/2, h/2-100)

    love.graphics.setColor(r2,g2,b2,a)
    love.graphics.setLineWidth(1.5)
    love.graphics.line(trX,trY,trX+trW,trY)
    for i=0,4 do
        if i==0 or i==4 then
            local tx=trX+i*(trW/4)
            love.graphics.setColor(r2,g2,b2,a)
            love.graphics.line(tx,trY-6,tx,trY+6)
        end
    end
    local kx=soloKnobX(w,h); local ks=11
    love.graphics.setColor(r2,g2,b2,a)
    love.graphics.rectangle("fill",math.floor(kx-ks/2),math.floor(trY-ks/2),ks,ks)

    local labels={tr("borders"),tr("fruits")}
    local vals={solo.borders,solo.fruits}
    local size=22
    for i=1,2 do
        local cy2=h/2+30+(i-1)*66
        local cx2=trX+trW-size/2
        love.graphics.setColor(r2,g2,b2,a)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line",math.floor(cx2),math.floor(cy2),size,size)
        if vals[i] then
            love.graphics.setLineWidth(2)
            local p=4
            love.graphics.line(cx2+p,cy2+size*0.55,cx2+size*0.42,cy2+size-p,cx2+size-p,cy2+p)
        end
        setCol("#111111",a)
        printBold(lblFont,labels[i],trX,cy2+size/2-lblFont:getHeight()/2)
    end
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("start"),w/2,h-80)
end

local loadingTimer  = 0
local loadingPhase  = "in"
local loadingSlide  = 0
local LOADING_IN    = 0.22
local LOADING_HOLD  = 2.0
local LOADING_OUT   = 0.28
local loadingFadeOut = 1

local function easeInOut(t)
    return t < 0.5 and 2*t*t or 1 - (-2*t+2)^2/2
end

local function easeOutCubic(t) return 1-(1-t)^3 end
local function easeInCubic(t)  return t*t*t end

local function drawLoading(w, h)
    local rectH = h * loadingSlide
    love.graphics.setColor(0x36/255, 0x35/255, 0x35/255, 1)
    love.graphics.rectangle("fill", 0, 0, w, rectH)

    love.graphics.setColor(1, 1, 1, 1)
    local txt = "..."
    love.graphics.setFont(btnFont)
    local tw = btnFont:getWidth(txt)
    local tx = math.floor(w/2 - tw/2)
    local ty = math.floor(rectH/2 - btnFont:getHeight()/2)
    for ox = -1, 1 do
        for oy = -1, 1 do
            love.graphics.print(txt, tx+ox, ty+oy)
        end
    end
    love.graphics.print(txt, tx, ty)
end

local function drawSecret(w,h,a)
    setCol("#111111",a)
    love.graphics.setFont(titleFont)
    local stitle = tr("secret_title")
    local tw = titleFont:getWidth(stitle)+2
    local tx = math.floor(w/2-tw/2); local ty = math.floor(h/2-160)
    love.graphics.print(stitle, tx,   ty)
    love.graphics.print(stitle, tx+1, ty)
    love.graphics.print(stitle, tx+2, ty)

    local labels = {tr("soft_bots"), tr("ultra"), tr("aim_col"), tr("show_fps")}
    local vals   = {secret.softBots, secret.ultraRicochet, secret.aimCollision, secret.showFps}
    local size   = 22
    local textX  = w/2 - 180   -- текст левее
    local cbxX   = w/2 + 160   -- чекбокс правее
    for i=1,#labels do
        local cy2 = h/2 - 30 + (i-1)*66
        local r2,g2,b2 = hex("#111111")
        love.graphics.setColor(r2, g2, b2, a)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", math.floor(cbxX), math.floor(cy2), size, size)
        if vals[i] then
            love.graphics.setLineWidth(2)
            local p=4
            love.graphics.line(cbxX+p, cy2+size*0.55, cbxX+size*0.42, cy2+size-p, cbxX+size-p, cy2+p)
        end
        setCol("#111111",a)
        printBold(lblFont, labels[i], textX, cy2 + size/2 - lblFont:getHeight()/2)
    end
    love.graphics.setColor(0, 0, 0, 1)
    local numItems = 4
    local resetY = h/2 - 30 + numItems*66
    setCol("#111111", a)
    local rlw = lblFont:getWidth(tr("reset_lang"))
    printBold(lblFont, tr("reset_lang"), math.floor(w/2 - rlw/2), resetY)
end

local function secretCheckGeom(w,h,idx)
    local size = 22
    local cbxX = w/2 + 160
    local cy2  = h/2 - 30 + (idx-1)*66
    return cbxX, cy2, size
end


local function drawSettings(w,h,a)
    setCol("#111111",a)
    love.graphics.setFont(titleFont)
    local stitle = tr("settings_title")
    local tw = titleFont:getWidth(stitle)+2
    local tx = math.floor(w/2-tw/2); local ty = math.floor(h/2-160)
    love.graphics.print(stitle, tx,   ty)
    love.graphics.print(stitle, tx+1, ty)
    love.graphics.print(stitle, tx+2, ty)

    setCol("#111111",a)
    printBoldCenter(btnFont, tr("language"), w/2, h/2 - 55)

    local size  = 22
    local textX = w/2 - 180
    local cbxX  = w/2 + 160
    local optLabels = {tr("opt_blood"), tr("opt_particles"), tr("opt_ring")}
    local optVals   = {settings.blood, settings.particles, settings.ring}
    for i = 1, #optLabels do
        local cy2 = h/2 + 20 + (i-1)*60
        local r2,g2,b2 = hex("#111111")
        love.graphics.setColor(r2,g2,b2,a)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", math.floor(cbxX), math.floor(cy2), size, size)
        if optVals[i] then
            love.graphics.setLineWidth(2)
            local p = 4
            love.graphics.line(cbxX+p, cy2+size*0.55, cbxX+size*0.42, cy2+size-p, cbxX+size-p, cy2+p)
        end
        setCol("#111111", a)
        printBold(lblFont, optLabels[i], textX, cy2 + size/2 - lblFont:getHeight()/2)
    end
end

local function drawLangPick(w,h,a)
    local lineH  = 52
    local visH   = h - 120          -- видимая область
    local maxScroll = math.max(0, #LANGS * lineH - visH)
    langScroll = math.max(0, math.min(langScroll, maxScroll))

    love.graphics.setScissor(0, 60, w, visH)
    love.graphics.setFont(btnFont)
    for i, name in ipairs(LANGS) do
        local y = 60 + (i-1)*lineH - langScroll
        if y + lineH < 60 or y > 60 + visH then -- вне области
        else
            if i == settings.lang then
                setCol("#111111", a)
            else
                setCol("#111111", a * 0.38)
            end
            local tw2 = btnFont:getWidth(name)
            local tx2 = math.floor(w/2 - tw2/2)
            love.graphics.print(name, tx2,   y)
            love.graphics.print(name, tx2+1, y)
            love.graphics.print(name, tx2+2, y)
        end
    end
    love.graphics.setScissor()
end

local function drawResult(w,h,a)
    setCol("#111111",a)
    local msg
    if game.winner == "player" then
        msg = tr("player_win")
    elseif game.winner == "draw" then
        msg = tr("draw") or "Draw"
    else
        msg = tr("ai_win")
    end
    printBoldCenter(btnFont, msg, w/2, h/2-40)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("again"), w/2, h/2+30)
    setCol("#111111",a)
    printBoldCenter(btnFont,tr("ok"),   w/2, h/2+85)
end

function love.load()
    love.window.setTitle("Tōlpanata")
    love.window.setMode(0,0,{fullscreen=true,fullscreentype="desktop",highdpi=true})
    love.graphics.setDefaultFilter("linear","linear",16)

    local function makeFont(size)
        return love.graphics.newFont("Rubik-VariableFont_wght.ttf", size)
    end

    titleFont = makeFont(45)
    btnFont   = makeFont(30)
    lblFont   = makeFont(26)
    hpFont    = love.graphics.newFont("Rubik-VariableFont_wght.ttf", 22)
    fpsFont   = love.graphics.newFont("Rubik-VariableFont_wght.ttf", 14)

    if love.filesystem.getInfo("click.ogg") then
        clickSfx = love.audio.newSource("click.ogg","static")
    end

    foodImages = {}
    for i = 1, 5 do
        local name = "food"..i..".png"
        if love.filesystem.getInfo(name) then
            local img = love.graphics.newImage(name, {mipmaps=true})
            img:setFilter("linear", "linear", 4)
            table.insert(foodImages, img)
        end
    end

    for i=1,NUM_BUBBLES do
        bubbles[i]=newBubble(love.math.random(-20,love.graphics.getHeight()))
    end
    loadSecret()
    loadSettings()
end

function love.update(dt)
    lastDt = dt
    if animT < 1 then
        animT = math.min(1, animT + dt*ANIM_SPD)
        if animT==1 then prevScreen=nil end
    end

    if curScreen=="game" then
        updateGame(dt)
        if loadingPhase == "hold" then
            loadingTimer = loadingTimer + dt
            loadingSlide = 1.0
            if loadingTimer >= LOADING_HOLD then
                loadingPhase = "out"
                loadingTimer = 0
            end
        elseif loadingPhase == "out" then
            loadingTimer = loadingTimer + dt
            loadingSlide = 1.0 - easeInOut(math.min(1, loadingTimer / LOADING_OUT))
            if loadingTimer >= LOADING_OUT then
                loadingSlide = 0
                loadingPhase = "idle"
                loadingTimer = 0
            end
        end
    elseif curScreen=="loading" then
        loadingTimer = loadingTimer + dt
        if loadingPhase == "in" then
            loadingSlide = easeOutCubic(math.min(1, loadingTimer / LOADING_IN))
            if loadingTimer >= LOADING_IN then
                loadingSlide = 1.0
                loadingPhase = "hold"
                loadingTimer = 0
            end
        elseif loadingPhase == "hold" then
            loadingSlide = 1.0
            if loadingTimer >= LOADING_HOLD then
                curScreen = "game"
                loadingPhase = "out"
                loadingTimer = 0
            end
        end
    else
        updateBubbles(dt)
    end
end

local function drawFpsOverlay()
    if not secret.showFps then return end
    local fps  = love.timer.getFPS()
    local ms   = math.floor(lastDt * 1000 * 10 + 0.5) / 10  -- до 0.1ms
    local ram  = math.floor(collectgarbage("count") / 102.4 + 0.5) / 10  -- в MB
    local str  = fps .. " FPS  " .. ms .. "ms  " .. ram .. "MB"
    love.graphics.setFont(fpsFont or lblFont)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.print(str, 6, 5)
end

function love.draw()
    local sw,sh = love.graphics.getDimensions()

    if curScreen == "loading" then
        local br,bg,bb = hex("#d3c0ed")
        love.graphics.setColor(br,bg,bb)
        love.graphics.rectangle("fill",0,0,sw,sh)
        drawBubbles()
        drawLoading(sw, sh)
        drawFpsOverlay()
        return
    end
    if curScreen == "game" then
        setCol("#8fc0c9")
        love.graphics.rectangle("fill",0,0,sw,sh)

        love.graphics.push()
        love.graphics.translate(sw/2 - game.camX, sh/2 - game.camY)
        drawArena()
        drawBlood()
        drawWalls()
        drawParticles()
        drawFruit()
        drawChips()
        love.graphics.pop()

        if not game.moving and not game.botThinking and not (game.turnDelay and game.turnDelay > 0) then
            local cur = game.chips[game.turn]
            if cur and cur.alive and not cur.isBot and game.sling.active then
                drawAimDots(cur, game.sling.mx, game.sling.my, game.camX, game.camY, sw, sh)
            end
        end

        drawHUD(sw,sh)
        if loadingPhase == "out" and loadingSlide > 0 then
            drawLoading(sw, sh)
        end
        drawFpsOverlay()
        return
    end

    local br,bg,bb = hex("#d3c0ed")
    love.graphics.setBackgroundColor(br,bg,bb)
    love.graphics.clear(br,bg,bb)
    if curScreen ~= "loading" then drawBubbles() end

    local screens = {main=drawMain, mode=drawMode, solo=drawSolo, result=drawResult, secret=drawSecret, settings=drawSettings, langpick=drawLangPick}

    if animT >= 1 then
        love.graphics.push()
        if screens[curScreen] then screens[curScreen](sw,sh,1) end
        love.graphics.pop()
    else
        local e    = easeOut(animT)
        local offOut = e * sh * 0.85
        local offIn  = (1-e) * sh * 0.85
        if prevScreen and screens[prevScreen] then
            love.graphics.push()
            love.graphics.translate(0, offOut)
            screens[prevScreen](sw, sh, 1-e)
            love.graphics.pop()
        end
        love.graphics.push()
        love.graphics.translate(0, offIn)
        if screens[curScreen] then screens[curScreen](sw, sh, e) end
        love.graphics.pop()
    end

    love.graphics.setColor(1,1,1,1)
    drawFpsOverlay()
end

function love.mousepressed(mx,my,btn)
    if btn ~= 1 then return end
    local sw,sh = love.graphics.getDimensions()

    if curScreen=="game" then
        if game.moving or game.botThinking or (game.turnDelay and game.turnDelay > 0) then return end
        local cur = game.chips[game.turn]
        if not cur or not cur.alive or cur.isBot then return end
        game.sling.active   = true
        game.sling.mx       = mx; game.sling.my = my
        game.sling.startMx  = mx; game.sling.startMy = my
        game.sling.dragged  = false
        game.mouseClicked   = true   -- скрываем полоски при нажатии
        return
    end

    if animT < 1 then return end

    if curScreen == "main" then
        if mx > sw - SECRET_ZONE and my > sh - SECRET_ZONE then
            if love.timer.getTime() - secretTapT > 1.2 then secretTaps = 0 end
            secretTaps = secretTaps + 1
            secretTapT = love.timer.getTime()
            if secretTaps >= 3 then
                secretTaps = 0
                playClick(); goTo("secret")
                return
            end
        end
    end

    if curScreen=="main" then
        if hitBtnCenter(btnFont,tr("play"),sw/2,sh/2+40,mx,my) then
            playClick(); goTo("mode")
        elseif hitBtnCenter(btnFont,tr("settings"),sw/2,sh/2+95,mx,my) then
            playClick(); goTo("settings")
        end
    elseif curScreen=="mode" then
        if hitBtnCenter(btnFont,tr("solo"),sw/2,sh/2-35,mx,my) then
            playClick(); goTo("solo")
        end
    elseif curScreen=="solo" then
        local trX,trY,trW = sliderGeom(sw,sh)
        if hitBox(trX-10,trY-14,trW+20,28,mx,my) then
            sliderDrag=true
            local t=math.max(0,math.min(1,(mx-trX)/trW))
            solo.players=math.max(2,math.min(6,math.floor(t*4+0.5)+2))
            playClick()
        end
        for i=1,2 do
            local cx2,cy2,size=checkGeom(sw,sh,i)
            if hitBox(cx2-6,cy2-6,size+12,size+12,mx,my) then
                playClick()
                if i==1 then solo.borders=not solo.borders
                else          solo.fruits =not solo.fruits end
            end
        end
        if hitBtnCenter(btnFont,tr("start"),sw/2,sh-80,mx,my) then
            playClick(); initGame()
            loadingPhase = "in"; loadingTimer = 0; loadingSlide = 0; loadingFadeOut = 1
            curScreen = "loading"
        end
    elseif curScreen=="settings" then
        local langBtnY = sh/2 - 55
        local lw2   = btnFont:getWidth(tr("language")) + 2
        local langBtnX = sw/2 - lw2/2
        if hitBox(langBtnX - 10, langBtnY - 5, lw2 + 20, btnFont:getHeight() + 10, mx, my) then
            playClick(); langScroll = 0; goTo("langpick")
        else
            local size = 22
            local cbxX = sw/2 + 160
            for i = 1, 3 do
                local cy2 = sh/2 + 20 + (i-1)*60
                if hitBox(cbxX-6, cy2-6, size+12, size+12, mx, my) then
                    playClick()
                    if     i==1 then settings.blood     = not settings.blood
                    elseif i==2 then settings.particles = not settings.particles
                    else             settings.ring      = not settings.ring end
                    saveSettings()
                end
            end
        end
    elseif curScreen=="langpick" then
        local lineH = 52
        for i, name in ipairs(LANGS) do
            local y = 60 + (i-1)*lineH - langScroll
            local tw2 = btnFont:getWidth(name)
            local tx2 = math.floor(sw/2 - tw2/2)
            if hitBox(tx2-8, y-4, tw2+16, lineH-4, mx, my) then
                playClick()
                settings.lang = i
                saveSettings()
                local function makeFont(size)
                    return love.graphics.newFont("Rubik-VariableFont_wght.ttf", size)
                end
                titleFont = makeFont(45)
                btnFont   = makeFont(30)
                lblFont   = makeFont(26)
                goBack()
                return
            end
        end
    elseif curScreen=="secret" then
        local numChecks = 4
        for i=1,numChecks do
            local cbx,cy2,size = secretCheckGeom(sw,sh,i)
            if hitBox(cbx-6,cy2-6,size+12,size+12,mx,my) then
                playClick()
                if     i==1 then secret.softBots      = not secret.softBots
                elseif i==2 then secret.ultraRicochet = not secret.ultraRicochet
                elseif i==3 then secret.aimCollision  = not secret.aimCollision
                elseif i==4 then secret.showFps       = not secret.showFps
                end
                saveSecret()
            end
        end
        local numItems2 = 4
        local resetY = sh/2 - 30 + numItems2*66
        local rlw = lblFont:getWidth(tr("reset_lang"))
        if hitBox(sw/2 - rlw/2 - 4, resetY - 4, rlw + 8, lblFont:getHeight() + 8, mx, my) then
            playClick()
            love.filesystem.remove("settings.dat")
            settings.lang = detectSystemLang()
            saveSettings()
        end
    elseif curScreen=="result" then
        if hitBtnCenter(btnFont,tr("again"),sw/2,sh/2+30,mx,my) then
            playClick(); initGame(); goTo("game")
        elseif hitBtnCenter(btnFont,tr("ok"),sw/2,sh/2+85,mx,my) then
            playClick(); goTo("main")
        end
    end
end

function love.mousereleased(mx,my,btn)
    if btn~=1 then return end
    sliderDrag=false

    if curScreen=="game" and game.sling.active then
        game.sling.active=false
        game.mouseClicked = false   -- отпустили — полоски возвращаются
        if game.moving or game.botThinking or (game.turnDelay and game.turnDelay > 0) then return end
        local cur = game.chips[game.turn]
        if not cur or not cur.alive or cur.isBot then return end
        if not game.sling.dragged then return end

        local sw,sh = love.graphics.getDimensions()
        local aim = calcAim(cur, game.sling.mx, game.sling.my, game.camX, game.camY, sw, sh)
        if not aim then return end
        cur.launchVx = aim.vx
        cur.launchVy = aim.vy
        cur.launchT  = 0
        cur.vx = 0; cur.vy = 0
        game.moving=true
        playClick()
    end
end

function love.mousemoved(mx,my)
    if sliderDrag and curScreen=="solo" then
        local sw,sh=love.graphics.getDimensions()
        local trX,_,trW=sliderGeom(sw,sh)
        local t=math.max(0,math.min(1,(mx-trX)/trW))
        solo.players=math.max(2,math.min(6,math.floor(t*4+0.5)+2))
    end
    if curScreen=="game" and game.sling.active then
        game.sling.mx=mx; game.sling.my=my
        if not game.sling.dragged then
            local ddx = mx - (game.sling.startMx or mx)
            local ddy = my - (game.sling.startMy or my)
            if ddx*ddx + ddy*ddy > 144 then
                game.sling.dragged = true
            end
        end
    end
end

function love.wheelmoved(x, y)
    if curScreen == "langpick" then
        langScroll = langScroll - y * 40
    end
end

function love.keypressed(key)
    if key=="escape" then
        if curScreen=="game" then
            curScreen="solo"; prevScreen=nil; animT=1
        elseif curScreen=="mode" or curScreen=="solo" or curScreen=="secret" or curScreen=="settings" or curScreen=="langpick" then
            playClick(); goBack()
        end
    end
end