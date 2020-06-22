local timer = require "util.timer";
local json = require "json";
local http = require "socket.http";
local serpent = require("serpent")
local iconv = require("iconv")

local STANZA = require "util.stanza";
local resend_time = 12
local minutes = 1
local last_time_checked = ""
local subscribers = {}
local subscribers_file_path = "/luigi/pizza_subscribers.txt"


function get_day(day)
    now = os.date("*t", os.time())
    if day == "yesterday" then
        now = {year = tonumber(now.year), month = tonumber(now.month), day = tonumber(now.day-1), hour = tonumber(now.hour), minutes = tonumber(now.min)}
    elseif day == "today" then
        now = {year = tonumber(now.year), month = tonumber(now.month), day = tonumber(now.day), hour = tonumber(now.hour), minutes = tonumber(now.min)}
    end
    return now
end

--args: yesterday, today
function has_a_day_passed(day_one, day_two)
    toReturn = false
    if day_one.year == day_two. year and 
        day_one.month == day_two.month and
        (day_one.day + 1 == day_two.day or day_one.day >= 30 and day_two.day == 1) then
        toReturn = true
    end
    
    return toReturn
end

-- before = os.time{year=2016, month=7, day=29, hour=12, sec=1}
-- now = os.time()
-- hours = 3
-- print(has_time_passed(before,now,hours))

--Returns whether the amount of hours passed as an argument has passed or not.
--timestamp, timestamp, hours
function has_time_passed(before, now, hours)
    toReturn = false

    if now < before then
       aux = now
       now = before
       before = aux
--        now, before = before, now 
    end
    
    if (now-before)/3600 >= hours then
        toReturn = true
    end
    
    return toReturn
end


function load_subscribers()
  local file = io.open(subscribers_file_path, "r")
  
  toReturn = false
  
  if file then
    ok, res = serpent.load(file:read("*a"), {safe = false})
    file:close()
    if ok then 
        subscribers = res
        toReturn = true
    end
  end
  
  return toReturn
end


function persist_subscribers()
    local file,err = io.open(subscribers_file_path, "w+")
    if file==nil then
        print("Couldn't open file: "..err)
    else
        file:write(serpent.block(subscribers))
        file:close()
    end
end


function search_maximum_price(pizzas, maximum_price)
    toReturn = ""
    if pizzas then
        for _,pizza in pairs(pizzas) do
--             if pizza.title:match("^.-(".. price .."- ?€).-$") then
            if pizza.title:match("^.-(%d+ -[€Ee]).-$") then
                title_price = tonumber(title:match("%d+"))
                if title_price <= maximum_price then
                    toReturn = toReturn .. pizza.title .. "\n" .. pizza.url .. "\n\n"    
                end
            end
        end
    end
    
    if toReturn ~= "" then
        toReturn = toReturn:sub(1,string.len(toReturn)-2)
    end
    
    return toReturn
end


function get_pizzas()
    pizzas = {}
    source = http.request("http://www.forocoches.com/foro/forumdisplay.php?f=69")
    cd = iconv.new("utf-8", "windows-1252//TRANSLIT") -- This line creates a conversion descriptor (to, from) --forocoches.com uses windows-1252 instead of what they advertise in their charset tag (ISO)
    
    if source then
        charset = source:match('charset=[\"\']?(.-)[\"\']'); -- This line gets the charset from the HTML
            for line in source:gmatch("(.-)\n") do
                    if line:find("thread_title") then
                            l = line:lower()
                            if l:find("pizza") then
                                url = "www.forocoches.com/foro/" .. line:match('href="(.-)"')
                                title = line:match(">(.-)</a>")
                                
                                title, err = cd:iconv(title) -- Converts the title string to utf-8
                                url, err = cd:iconv(url) -- Converts the title string to utf-8
                                
                                row = {title = title, url = url}
                                table.insert(pizzas, row)
                            end
                    end
            end
    end
    --Add here last_time_checked
    return next(pizzas) and pizzas or nil
end

function get_pizzas_text()
    pizzas = get_pizzas()
    text = "There are no pizzas! :( Last time I checked: " .. os.date("%H:%M:%S %d/%m/%Y",last_time_checked)
    if pizzas then
        text = ""
        for _,pizza in pairs(pizzas) do
            text = text .. pizza.title .. "\n" .. pizza.url .. "\n\n"
        end
        text = text:sub(1,string.len(text)-2)
    end
    return text
end

function send_pizzas_muc(room,pizzas)
   room:send_message(get_pizzas_text)                    
end


function send_pizzas_jid(jid,pizzas_text,bot)
    bot:send(STANZA.message({ to = jid, type = "headline" }):body(pizzas_text))
end

function add_subscriber(jid, maximum_price)
    load_subscribers()
    if not subscribers then
        subscribers = {}
    end
    
    i = 1
    found = false

    for k, subscriber in pairs(subscribers) do
        if subscriber.jid == jid then
            subscriber.maximum_price = maximum_price
            subscriber.last_time_sent = 0
            found = true
        end
        
    end
    
    if not found then
        subscribers[#subscribers + 1] = {jid = jid, maximum_price = maximum_price, last_time_sent = 0, already_sent = {}}
    end

    persist_subscribers()
end


-- Check, for every available pizza, if it matches the maximum_price. 
-- If so, check in subscribers' already_sent, if it is already sent or not. If not, send it.
function filter_pizzas_by_maximum_price(pizzas, maximum_price)
    toReturn = {}
    if pizzas then
        for _,pizza in pairs(pizzas) do
            coin = pizza.title:match("^.-(%d+ -[€Ee]).-$")
            match = coin and coin:match("%d+")
            if match then
                title_price = tonumber(match)
                if title_price <= maximum_price then
                    toReturn[#toReturn +1] = pizza
                end
            end
        end
    end

    return next(toReturn) and toReturn or nil   
end

--Check if a subscriber has received the pizza passed as argument
function has_received_pizza(subscriber,pizza)
    toReturn = false
    if subscriber.already_sent then
       if #subscriber.already_sent > 0 then
           for k, v in pairs(subscriber.already_sent) do
              if v.title == pizza.title then
                 toReturn = true 
              end
           end
       end
    end
    
    return toReturn
end

function get_message(subscriber, pizzas)
    message = ""
    filtered_pizzas = filter_pizzas_by_maximum_price(pizzas, subscriber.maximum_price)
    if filtered_pizzas then
        for _, pizza in pairs(filtered_pizzas) do
           if not has_received_pizza(subscriber, pizza) then
                message = message .. pizza.title .. "\n" .. pizza.url .. "\n\n"
                --This should not go here. Creating a message does not mean actually sending it
                subscriber.already_sent[#subscriber.already_sent + 1] = pizza
           end
        end
    end
    
    if message ~= "" then
        message = message:sub(1,string.len(message)-2)
    end
    
    return message
end

function riddim.plugins.pizza(bot)
    load_subscribers()
    
    local function process_message(event)
        reply = ""
        local body = event.body;
    --     if not body then return; end
        if body then
            if body:lower():match("^pizza$") or body:lower():match("^pizzes$") then
                reply = get_pizzas_text()
            elseif body:match("^%d+$") then
                if tonumber(body) > 0 then
                    add_subscriber(event.sender.jid:match("^(.-)/"), tonumber(body))
--                     for k,v in pairs(event) do print(k,v) end
                    if tonumber(body) >= 1 and tonumber(body) < 8 then
                        reply = "Wow, you are really mean. I'll see what I can do with " .. body .. "€ but I can't promise anything."
                    end
                else
                    reply = body .. " €? Really? Come on 😑"
                end
            end
            
        end
        
        --Answer
        if reply ~= "" then
            bot:send(STANZA.reply(event.stanza):body(reply))
        end
        
    end
    
    bot:hook("message", process_message);
    
    -- Search for pizzas with a price lower or equal than the defined by a contact
    -- send them pizza offers if any is found
    timer.add_task(1, 
        function ()
            pizzas = get_pizzas()
            if subscribers then
                for k, v in pairs(subscribers) do
                    if has_time_passed(v.last_time_sent, os.time(), resend_time) then
                        v.already_sent = {}
                    end
                    
                    reply = get_message(v, pizzas)
                    if reply ~= "" then
                        send_pizzas_jid(v.jid, reply, bot)
                        v.last_time_sent = os.time()
                        persist_subscribers()
                    end 
                end    
            end
            
            last_time_checked = os.time()
            return minutes * 60
        end
    );
end 


