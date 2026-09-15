-- zh_simplified_chars.lua -- characters that exist in simplified Chinese but not in
-- traditional, shared by the tools that check a zh-tw/zh-hk result.
--
-- Deliberately conservative: every character here has a *different* traditional
-- counterpart (动/動, 们/們, 车/車 ...), so a hit is always a real simplified character.
-- Characters shared by both variants (后, 只, 里 ...) and Japanese-only forms are left
-- out, which makes any count a lower bound rather than an overstatement.
return {
    "们", "这", "说", "动", "时", "个", "见", "车", "马", "门", "关", "开", "长", "万",
    "与", "东", "乐", "书", "会", "学", "国", "图", "团", "园", "场", "声", "头", "页",
    "风", "飞", "饭", "饮", "馆", "骑", "验", "铁", "银", "钱", "钟", "险", "队", "员",
    "军", "农", "边", "过", "还", "进", "远", "运", "连", "迟", "适", "选", "递", "邮",
    "乡", "亲", "爱", "敌", "数", "断", "无", "旧", "显", "术", "机", "权", "极", "标",
    "样", "树", "桥", "检", "楼", "欢", "欧", "岁", "历", "残", "杀", "杂", "条", "来",
    "构", "枪", "档", "汇", "汉", "汤", "沟", "没", "让", "认", "讲", "论", "试", "语",
    "读", "谁", "谢", "变", "电", "视", "觉", "观", "规", "训", "记", "话", "货", "质",
    "贴", "费", "赚", "赛", "胜", "败", "输", "转", "轮", "软", "较", "辆", "载", "办",
    "务", "单", "卖", "买", "资", "赏", "赠", "赶", "趋",
}
