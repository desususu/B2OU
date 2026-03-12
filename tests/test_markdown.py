from b2ou.markdown import (
    bear_highlight_to_md,
    clean_title,
    hide_tags,
    extract_tags,
    html_img_to_markdown,
    normalise_bear_markdown,
    ref_links_to_inline,
    first_heading,
)

def test_clean_title():
    # RE_CLEAN_TITLE only replaces /\:
    assert clean_title("Hello World!") == "Hello World!"
    assert clean_title("Tag #test and /path/") == "Tag #test and -path"
    assert clean_title("   Spaces   ") == "Spaces"
    assert clean_title("") == "Untitled"

def test_clean_title_utf8_byte_limit():
    # 100 emoji = 400 bytes UTF-8, should be capped to 240 bytes (60 emoji)
    title = "\U0001f389" * 100
    result = clean_title(title)
    assert len(result.encode("utf-8")) <= 240
    assert len(result) == 60

def test_extract_tags():
    text = "Hello #tag1 and #tag2/subtag.\nAlso #tag3# with spaces."
    tags = extract_tags(text)
    assert "tag1" in tags
    # The regex includes trailing dots/dashes
    assert "tag2/subtag." in tags
    assert "tag3" in tags

def test_hide_tags():
    text = "#heading\n#tag1\nContent\n#tag2 #tag3"
    hidden = hide_tags(text)
    assert "#tag1" not in hidden
    # hide_tags strips the entire line if it starts with #
    assert "#tag2" not in hidden
    assert "Content" in hidden

def test_html_img_to_markdown():
    html = '<img src="test.png" alt="Description">'
    expected = "![Description](test.png)"
    assert html_img_to_markdown(html) == expected

    html_no_alt = '<img src="test.png">'
    assert html_img_to_markdown(html_no_alt) == "![image](test.png)"

def test_ref_links_to_inline():
    text = "[link][1]\n![img][2]\n\n[1]: https://google.com\n[2]: img.png"
    expected = "[link](https://google.com)\n![img](img.png)\n\n"
    assert ref_links_to_inline(text).strip() == expected.strip()

def test_bear_highlight_to_md():
    assert bear_highlight_to_md("Hello ::world:: end") == "Hello ==world== end"
    assert bear_highlight_to_md("::multi word highlight::") == "==multi word highlight=="
    # Triple colons should not be converted
    assert bear_highlight_to_md(":::not a highlight:::") == ":::not a highlight:::"
    # No match on single colons
    assert bear_highlight_to_md("a:b:c") == "a:b:c"

def test_normalise_bear_markdown():
    text = '::highlighted:: and <img src="photo.jpg" alt="pic">'
    result = normalise_bear_markdown(text)
    assert "==highlighted==" in result
    assert "![pic](photo.jpg)" in result

def test_first_heading():
    assert first_heading("# Title\nContent") == "Title"
    assert first_heading("  ## Subtitle  \nMore") == "Subtitle"
    assert first_heading("\n\nNo Hash Title") == "No Hash Title"
