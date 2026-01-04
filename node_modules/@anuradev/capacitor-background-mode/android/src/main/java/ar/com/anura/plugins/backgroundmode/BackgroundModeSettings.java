package ar.com.anura.plugins.backgroundmode;

import java.io.Serializable;

public class BackgroundModeSettings implements Serializable {
  public static final String DEFAULT_TITLE = "App is on background mode";
  public static final String DEFAULT_TEXT = "App will start faster";
  public static final String DEFAULT_SUB_TEXT = "";
  public static final Boolean DEFAULT_BIG_TEXT = false;
  public static final Boolean DEFAULT_RESUME = true;
  public static final Boolean DEFAULT_SILENT = false;
  public static final Boolean DEFAULT_HIDDEN = true;
  public static final String DEFAULT_COLOR = "157f1f";
  public static final String DEFAULT_ICON = "icon";
  public static final String DEFAULT_CHANNEL_NAME = "anuradev-capacitor-background-mode";
  public static final String DEFAULT_CHANNEL_DESCRIPTION = "Anuradev Capacitor background mode notification";
  public static final Boolean DEFAULT_ALLOW_CLOSE = false;
  public static final String DEFAULT_CLOSE_ICON = "close-icon";
  public static final String DEFAULT_CLOSE_TITLE = "Close";
  public static final Boolean DEFAULT_SHOW_WHEN = true;
  public static final Visibility DEFAULT_VISIBILITY = Visibility.PUBLIC;
  public static final Boolean DEFAULT_DISABLE_WEB_VIEW_OPTIMIZATION = true;

  private String title;
  private String text;
  private String subText;
  private Boolean bigText;
  private Boolean resume;
  private Boolean silent;
  private Boolean hidden;
  private String color;
  private String icon;
  private String channelName;
  private String channelDescription;
  private Boolean allowClose;
  private String closeIcon;
  private String closeTitle;
  private Boolean showWhen;
  private Visibility visibility;
  private Boolean disableWebViewOptimization;

  private BackgroundModeSettings(Builder builder, boolean applyDefaults) {
    if (applyDefaults) {
      this.title = builder.title != null ? builder.title : DEFAULT_TITLE;
      this.text = builder.text != null ? builder.text : DEFAULT_TEXT;
      this.subText = builder.subText != null ? builder.subText : DEFAULT_SUB_TEXT;
      this.bigText = builder.bigText != null ? builder.bigText : DEFAULT_BIG_TEXT;
      this.resume = builder.resume != null ? builder.resume : DEFAULT_RESUME;
      this.silent = builder.silent != null ? builder.silent : DEFAULT_SILENT;
      this.hidden = builder.hidden != null ? builder.hidden : DEFAULT_HIDDEN;
      this.color = builder.color != null ? builder.color : DEFAULT_COLOR;
      this.icon = builder.icon != null ? builder.icon : DEFAULT_ICON;
      this.channelName = builder.channelName != null ? builder.channelName : DEFAULT_CHANNEL_NAME;
      this.channelDescription = builder.channelDescription != null ? builder.channelDescription : DEFAULT_CHANNEL_DESCRIPTION;
      this.allowClose = builder.allowClose != null ? builder.allowClose : DEFAULT_ALLOW_CLOSE;
      this.closeIcon = builder.closeIcon != null ? builder.closeIcon : DEFAULT_CLOSE_ICON;
      this.closeTitle = builder.closeTitle != null ? builder.closeTitle : DEFAULT_CLOSE_TITLE;
      this.showWhen = builder.showWhen != null ? builder.showWhen : DEFAULT_SHOW_WHEN;
      this.visibility = builder.visibility != null ? builder.visibility : DEFAULT_VISIBILITY;
      this.disableWebViewOptimization = builder.disableWebViewOptimization != null ? builder.disableWebViewOptimization : DEFAULT_DISABLE_WEB_VIEW_OPTIMIZATION;
    } else {
      this.title = builder.title;
      this.text = builder.text;
      this.subText = builder.subText;
      this.bigText = builder.bigText;
      this.resume = builder.resume;
      this.silent = builder.silent;
      this.hidden = builder.hidden;
      this.color = builder.color;
      this.icon = builder.icon;
      this.channelName = builder.channelName;
      this.channelDescription = builder.channelDescription;
      this.allowClose = builder.allowClose;
      this.closeIcon = builder.closeIcon;
      this.closeTitle = builder.closeTitle;
      this.showWhen = builder.showWhen;
      this.visibility = builder.visibility;
      this.disableWebViewOptimization = builder.disableWebViewOptimization;
    }
  }


  public static class Builder {
    private String title;
    private String text;
    private String subText;
    private Boolean bigText;
    private Boolean resume;
    private Boolean silent;
    private Boolean hidden;
    private String color;
    private String icon;
    private String channelName;
    private String channelDescription;
    private Boolean allowClose;
    private String closeIcon;
    private String closeTitle;
    private Boolean showWhen;
    private Visibility visibility;
    private Boolean disableWebViewOptimization;

    public Builder title(String title) { this.title = title; return this; }
    public Builder text(String text) { this.text = text; return this; }
    public Builder subText(String subText) { this.subText = subText; return this; }
    public Builder bigText(Boolean bigText) { this.bigText = bigText; return this; }
    public Builder resume(Boolean resume) { this.resume = resume; return this; }
    public Builder silent(Boolean silent) { this.silent = silent; return this; }
    public Builder hidden(Boolean hidden) { this.hidden = hidden; return this; }
    public Builder color(String color) { this.color = color; return this; }
    public Builder icon(String icon) { this.icon = icon; return this; }
    public Builder channelName(String channelName) { this.channelName = channelName; return this; }
    public Builder channelDescription(String channelDescription) { this.channelDescription = channelDescription; return this; }
    public Builder allowClose(Boolean allowClose) { this.allowClose = allowClose; return this; }
    public Builder closeIcon(String closeIcon) { this.closeIcon = closeIcon; return this; }
    public Builder closeTitle(String closeTitle) { this.closeTitle = closeTitle; return this; }
    public Builder showWhen(Boolean showWhen) { this.showWhen = showWhen; return this; }
    public Builder visibility(Visibility visibility) { this.visibility = visibility; return this; }
    public Builder disableWebViewOptimization(Boolean disableWebViewOptimization) { this.disableWebViewOptimization = disableWebViewOptimization; return this; }

    public BackgroundModeSettings build() {
      return new BackgroundModeSettings(this, true);
    }

    public BackgroundModeSettings buildRaw() {
      return new BackgroundModeSettings(this, false);
    }
  }

  public String getTitle() {
    return title;
  }

  public String getText() {
    return text;
  }

  public String getSubText() {
    return subText;
  }

  public Boolean getBigText() {
    return bigText;
  }

  public Boolean getResume() {
    return resume;
  }

  public Boolean getSilent() {
    return silent;
  }

  public Boolean getHidden() {
    return hidden;
  }

  public String getColor() {
    return color;
  }

  public String getIcon() {
    return icon;
  }

  public String getChannelName() {
    return channelName;
  }

  public String getChannelDescription() {
    return channelDescription;
  }

  public Boolean getAllowClose() {
    return allowClose;
  }

  public String getCloseIcon() {
    return closeIcon;
  }

  public String getCloseTitle() {
    return closeTitle;
  }

  public Boolean getShowWhen() {
    return showWhen;
  }

  public Visibility getVisibility() {
    return visibility;
  }

  public boolean isDisableWebViewOptimization() {
    return disableWebViewOptimization;
  }

  public void setTitle(String title) {
    this.title = title;
  }

  public void setText(String text) {
    this.text = text;
  }

  public void setSubText(String subText) {
    this.subText = subText;
  }

  public void setBigText(Boolean bigText) {
    this.bigText = bigText;
  }

  public void setResume(Boolean resume) {
    this.resume = resume;
  }

  public void setSilent(Boolean silent) {
    this.silent = silent;
  }

  public void setHidden(Boolean hidden) {
    this.hidden = hidden;
  }

  public void setColor(String color) {
    this.color = color;
  }

  public void setIcon(String icon) {
    this.icon = icon;
  }

  public void setChannelName(String channelName) {
    this.channelName = channelName;
  }

  public void setChannelDescription(String channelDescription) {
    this.channelDescription = channelDescription;
  }

  public void setAllowClose(Boolean allowClose) {
    this.allowClose = allowClose;
  }

  public void setCloseIcon(String closeIcon) {
    this.closeIcon = closeIcon;
  }

  public void setCloseTitle(String closeTitle) {
    this.closeTitle = closeTitle;
  }

  public void setShowWhen(Boolean showWhen) {
    this.showWhen = showWhen;
  }

  public void setVisibility(Visibility visibility) {
    this.visibility = visibility;
  }

  public void setDisableWebViewOptimization(boolean disableWebViewOptimization) {
    this.disableWebViewOptimization = disableWebViewOptimization;
  }

  public BackgroundModeSettings merge(BackgroundModeSettings override) {
    return new Builder()
      .title(override.title != null ? override.title : this.title)
      .text(override.text != null ? override.text : this.text)
      .subText(override.subText != null ? override.subText : this.subText)
      .bigText(override.bigText != null ? override.bigText : this.bigText)
      .resume(override.resume != null ? override.resume : this.resume)
      .silent(override.silent != null ? override.silent : this.silent)
      .hidden(override.hidden != null ? override.hidden : this.hidden)
      .color(override.color != null ? override.color : this.color)
      .icon(override.icon != null ? override.icon : this.icon)
      .channelName(override.channelName != null ? override.channelName : this.channelName)
      .channelDescription(override.channelDescription != null ? override.channelDescription : this.channelDescription)
      .allowClose(override.allowClose != null ? override.allowClose : this.allowClose)
      .closeIcon(override.closeIcon != null ? override.closeIcon : this.closeIcon)
      .closeTitle(override.closeTitle != null ? override.closeTitle : this.closeTitle)
      .showWhen(override.showWhen != null ? override.showWhen : this.showWhen)
      .visibility(override.visibility != null ? override.visibility : this.visibility)
      .disableWebViewOptimization(override.disableWebViewOptimization != null ? override.disableWebViewOptimization : this.disableWebViewOptimization)
      .build();
  }
}
