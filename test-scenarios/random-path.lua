-- Sends GET requests to /path?value=random
math.randomseed(os.time())

request = function()
  local val = math.random(1, 1000000)
  return string.format("GET /?v=%d HTTP/1.1\r\nHost: 4.236.46.39\r\n\r\n", val)
end
