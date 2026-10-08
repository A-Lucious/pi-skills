from shopping_aggregator.providers import get_provider


JD_CARD = """data-sku="100044817328"><div class="_wrapper_o085i_24" title="佳能（Canon）R50微单相机 京东自营"><img src="//img13.360buyimg.com/n2/item.png"></div><span title="佳能（Canon）R50微单相机 京东自营" class="_newStyle_1k2fi_39">佳能R50</span><span class="_price_65r2s_22"><i class="_yen_65r2s_18">¥</i><span>5297</span><span>.</span><span class="_decimal_65r2s_36">4</span></span><span class="_limit_zclqt_23">佳能影像京东自营旗舰店</span>"""


TAOBAO_CARD = """<div class="title--ASSt27UY " title="佳能r50照相机入门蚂蚁摄影数码官方Canon佳能EOSR50"><span>佳能r50照<span>相机</span></span></div><div class="priceWrapper--dBtPZ2K1"><span class="unit--D3KGoZe2">¥</span><div class="priceInt--yqqZMJ5a">7320</div><div class="priceFloat--XpixvyQ1"></div><span class="realSales--XZJiepmt">2人付款</span><div class="procity--wlcT2xH9"><span>山东</span></div><div class="procity--wlcT2xH9"><span>烟台</span></div></div>"""


def test_jd_extracts_react_search_cards():
    items = get_provider("jd").extract(JD_CARD)
    assert items[0].title == "佳能（Canon）R50微单相机 京东自营"
    assert items[0].url == "https://item.jd.com/100044817328.html"
    assert items[0].price == "5297.4"
    assert items[0].shop == "佳能影像京东自营旗舰店"


def test_taobao_extracts_2025_search_cards():
    items = get_provider("taobao").extract(TAOBAO_CARD)
    assert items[0].title == "佳能r50照相机入门蚂蚁摄影数码官方Canon佳能EOSR50"
    assert items[0].price == "7320"
    assert items[0].location == "山东 烟台"


def test_taobao_logged_in_shell_is_not_login_required():
    html = '<body class="site-nav-status-login"><script src="https://login.taobao.com/static/login.js"></script></body>'
    assert get_provider("taobao").login_required(html) is False
