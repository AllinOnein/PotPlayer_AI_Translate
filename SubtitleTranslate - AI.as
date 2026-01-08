/*
    Real-time subtitle translation for PotPlayer using AI API
*/

// Plugin Information Functions
string GetTitle() {
    return "{$CP0=AI Translate$}";
}

string GetVersion() {
    return "1.0";
}

string GetDesc() {
    return "{$CP0=Real-time subtitle translation using AI$}";
}

string GetLoginTitle() {
    return "{$CP0=API Key Configuration$}";
}

string GetLoginDesc() {
    return "{$CP936=在用户名处输入：模型名称|API地址。在密码处输入API密钥。$}";
}

string GetPasswordText() {
    return "{$CP0=API Key:$}";
}

// 全局变量Global Variables
string api_key = ""; // 用于存储 API Key
string selected_model = ""; // 用于储存模型名称
string apiUrl = ""; // 用于储存 URL
string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
int maxRetries = 3; // Maximum number of retries for translation
int retryDelay = 1000; // Delay between retries in milliseconds

// Supported Language List
array<string> LangTable =
{
    "{$CP0=Auto Detect$}", "af", "sq", "am", "ar", "hy", "az", "eu", "be", "bn", "bs", "bg", "ca",
    "ceb", "ny", "zh-CN",
    "zh-TW", "co", "hr", "cs", "da", "nl", "en", "eo", "et", "tl", "fi", "fr",
    "fy", "gl", "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is", "ig", "id", "ga", "it", "ja", "jw", "kn", "kk", "km",
    "ko", "ku", "ky", "lo", "la", "lv", "lt", "lb", "mk", "ms", "mg", "ml", "mt", "mi", "mr", "mn", "my", "ne", "no", "ps", "fa", "pl", "pt",
    "pa", "ro", "ru", "sm", "gd", "sr", "st", "sn", "sd", "si", "sk", "sl", "so", "es", "su", "sw", "sv", "tg", "ta", "te", "th", "tr", "uk",
    "ur", "uz", "vi", "cy", "xh", "yi", "yo", "zu"
};

// Get Source Language List
array<string> GetSrcLangs() {
    array<string> ret = LangTable;
    return ret;
}

// Get Destination Language List
array<string> GetDstLangs() {
    array<string> ret = LangTable;
    return ret;
}

// Login Interface for entering API Key
string ServerLogin(string User, string Pass) {
    // Trim whitespace from both inputs
    User = User.Trim();
    Pass = Pass.Trim();

    // Validate both inputs
    if (Pass.empty()) {
        HostPrintUTF8("{$CP0=API Key not configured. Please enter a valid API Key.$}\n");
        return "fail: API Key is empty";
    }
    if (User.empty()) {
        HostPrintUTF8("{$CP0=Model and API URL not configured. Please enter in format: ModelName|APIURL$}\n");
        return "fail: Model and API URL not configured";
    }

    // 解析用户名字段：格式为 "模型名称|API地址"
    array<string> modelParts = User.split("|");
    
    if (modelParts.length() < 2) {
        HostPrintUTF8("{$CP0=Invalid model configuration format. Please use: ModelName|APIURL$}\n");
        return "fail: Invalid model configuration format";
    }
    
    // 提取模型和API地址
    selected_model = modelParts[0].Trim();
    apiUrl = modelParts[1].Trim();

    // 验证模型和API地址是否为空
    if (selected_model.empty() || apiUrl.empty()) {
        HostPrintUTF8("{$CP0=Model name and API URL must be non-empty.$}\n");
        return "fail: Model name or API URL is empty";
    }


    // 保存API密钥
    api_key = Pass;

    // Save all configuration to temporary storage
    HostSaveString("api_key", api_key);
    HostSaveString("selected_model", selected_model);
    HostSaveString("apiUrl", apiUrl);
    HostPrintUTF8("{$CP0=Configuration successfully saved. Model: $}" + selected_model + 
                  "{$CP0=, API: $}" + apiUrl + "\n");
    return "200 ok";
}

// JSON String Escape Function
string JsonEscape(const string &in input) {
    string output = input;
    output.replace("\\", "\\\\");
    output.replace("\"", "\\\"");
    output.replace("\n", "\\n");
    output.replace("\r", "\\r");
    output.replace("\t", "\\t");
    return output;
}

// Global variables for storing previous subtitles
array<string> subtitleHistory;
string UNICODE_RLE = "\u202B"; // For Right-to-Left languages

// Function to estimate token count based on character length
int EstimateTokenCount(const string &in text) {
    // Rough estimation: average 4 characters per token
    return int(float(text.length()) / 4);
}

// Function to get the model's maximum context length
int GetModelMaxTokens(const string &in modelName) {
    // Define maximum tokens for known models
    if (modelName == "deepseek-chat") {
        return 4096; // DeepSeek模型的默认最大token数
    } else {
        // Default to a conservative limit
        return 4096;
    }
}

// Translation Function with Retry Mechanism
string Translate(string Text, string &in SrcLang, string &in DstLang) {
    // 检查 API Key 是否已配置
    if (api_key.empty()) {
        HostPrintUTF8("{$CP0=API Key not configured. Please enter it in the settings menu.$}\n");
        return "Translation failed: API Key not configured";
    }

    // 检查模型是否已配置
    if (selected_model.empty()) {
        HostPrintUTF8("{$CP0=Model not configured. Please configure in settings.$}\n");
        return "Translation failed: Model not configured";
    }
    
    // 检查API地址是否已配置
    if (apiUrl.empty()) {
        HostPrintUTF8("{$CP0=API URL not configured. Please configure in settings.$}\n");
        return "Translation failed: API URL not configured";
    }

    if (DstLang.empty() || DstLang == "{$CP0=Auto Detect$}") {
        HostPrintUTF8("{$CP0=Target language not specified. Please select a target language.$}\n");
        return "Translation failed: Target language not specified";
    }

    if (SrcLang.empty() || SrcLang == "{$CP0=Auto Detect$}") {
        SrcLang = "";
    }

    // Add the current subtitle to the history
    subtitleHistory.insertLast(Text);

    // Get the model's maximum token limit
    int maxTokens = GetModelMaxTokens(selected_model);

    // Build the context from the subtitle history
    string context = "";
    int tokenCount = EstimateTokenCount(Text); // Tokens used by the current subtitle
    int i = int(subtitleHistory.length()) - 2; // Start from the previous subtitle
    while (i >= 0 && tokenCount < (maxTokens - 1000)) { // Reserve tokens for response and prompt
        string subtitle = subtitleHistory[i];
        int subtitleTokens = EstimateTokenCount(subtitle);
        tokenCount += subtitleTokens;
        if (tokenCount < (maxTokens - 1000)) {
            context = subtitle + "\n" + context;
        }
        i--;
    }

    // Limit the size of subtitleHistory to prevent it from growing indefinitely
    if (subtitleHistory.length() > 1000) {
        subtitleHistory.removeAt(0);
    }

    // Construct the prompt
    string prompt = "You are a professional subtitle translator. Translate the following text into natural and fluent language. Use the provided context to optimize phrasing, but do not include it in the output. If needed, adjust sentence segmentation for readability, but avoid altering the original meaning or creating overly long sentences. For ambiguous terms, prioritize the meaning that best fits the context. Output only the translated result, without additional explanations or notes. **Ensure the translation does not contain any punctuation marks, as subtitles typically do not use them.** If the content violates safety standards, provide a compliant translation.";
    if (!SrcLang.empty()) {
        prompt += " Translate from " + SrcLang;
    }
    prompt += " to " + DstLang + ". Use the provided context only to maintain coherence, but do not include the context in the output.\n";
    if (!context.empty()) {
        prompt += "Context:\n" + context + "\n";
    }
    prompt += "Subtitle to translate:\n" + Text;


    // JSON escape
    string escapedPrompt = JsonEscape(prompt);

    // Request data
    string requestData = "{\"model\":\"" + selected_model + "\","
                         "\"messages\":[{\"role\":\"user\",\"content\":\"" + escapedPrompt + "\"}],"
                         "\"max_tokens\":1000,\"temperature\":0}";

    string headers = "Authorization: Bearer " + api_key + "\nContent-Type: application/json";

    // Retry mechanism
    int retryCount = 0;
    while (retryCount < maxRetries) {
        // Send request
        string response = HostUrlGetString(apiUrl, UserAgent, headers, requestData);
        if (response.empty()) {
            HostPrintUTF8("{$CP0=Translation request failed. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
            continue;
        }

        // Parse response
        JsonReader Reader;
        JsonValue Root;
        if (!Reader.parse(response, Root)) {
            HostPrintUTF8("{$CP0=Failed to parse API response. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
            continue;
        }

        JsonValue choices = Root["choices"];
        if (choices.isArray() && choices[0]["message"]["content"].isString()) {
            string translatedText = choices[0]["message"]["content"].asString();

            // 处理多行翻译结果：只取最后一行
            translatedText = translatedText.Trim(); // 去除多余的空格
            if (translatedText.find("\n") != -1) {
                array<string> lines = translatedText.split("\n");
                translatedText = lines[lines.length() - 1].Trim(); // 取最后一行
            }

            // 处理 RTL 语言
            if (DstLang == "fa" || DstLang == "ar" || DstLang == "he") {
                translatedText = UNICODE_RLE + translatedText;
            }

            SrcLang = "UTF8";
            DstLang = "UTF8";
            return translatedText;
        }

        // Handle API errors
        if (Root["error"]["message"].isString()) {
            string errorMessage = Root["error"]["message"].asString();
            HostPrintUTF8("{$CP0=API Error: $}" + errorMessage + "\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
        } else {
            HostPrintUTF8("{$CP0=Translation failed. Retrying...$}\n");
            retryCount++;
            HostSleep(retryDelay); // Delay before retrying
        }
    }

    // If all retries fail, return an error message
    HostPrintUTF8("{$CP0=Translation failed after maximum retries.$}\n");
    return "Translation failed: Maximum retries reached. ";
}

// Plugin Initialization
void OnInitialize() {
    HostPrintUTF8("{$CP0=AI translation plugin loaded.$}\n");

    // 从持久化存储中加载所有配置
    api_key = HostLoadString("api_key", "");
    selected_model = HostLoadString("selected_model", "");
    apiUrl = HostLoadString("apiUrl", "");

    // 检查所有配置是否完整
    if (!api_key.empty() && !selected_model.empty() && !apiUrl.empty()) {
        HostPrintUTF8("{$CP0=Saved configuration loaded. Model: $}" + selected_model + 
                      "{$CP0=, API: $}" + apiUrl + "\n");
    } else if (api_key.empty() && selected_model.empty() && apiUrl.empty()) {
        HostPrintUTF8("{$CP0=No saved configuration found. Please configure in settings.$}\n");
    } else {
        // 部分配置缺失的情况
        HostPrintUTF8("{$CP0=Configuration incomplete. Missing: $}");
        if (api_key.empty()) HostPrintUTF8("{$CP0=API Key $}");
        if (selected_model.empty()) HostPrintUTF8("{$CP0=Model name $}");
        if (apiUrl.empty()) HostPrintUTF8("{$CP0=API URL $}");
        HostPrintUTF8("{$CP0=. Please reconfigure.$}\n");
        
        // 清空不完整的配置
        api_key = "";
        selected_model = "";
        apiUrl = "";
    }
}

// Plugin Finalization
void OnFinalize() {
    HostPrintUTF8("{$CP0=AI translation plugin unloaded.$}\n");
}
