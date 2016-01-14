# name: notification-email-template
# version: 0.1

after_initialize do

  # Adds a head with title and meta tags to the message html string before it is
  # used to initialize Email::Styles
  Email::Renderer.class_eval do
    def title
      @message.subject ? @message.subject : "An email from #{SiteSetting.title}"
    end

    def head
      <<-HEAD
<html lang="#{SiteSetting.default_locale}">
<head>
  <meta charset="UTF-8">
  <title>#{title}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
</head>
<body>
      HEAD
    end

    def create_document(body_contents)
      head + body_contents + "</body></html>"
    end

    def html
      if @message.html_part
        style = Email::Styles.new(create_document(@message.html_part.body.to_s), @opts)
        style.format_basic
        style.format_html
      else
        style = Email::Styles.new(create_document(PrettyText.cook(text)), @opts)
        style.format_basic
      end
      style.to_html
    end
  end

  # Use the full document instead of `Nokogiri::HTML.fragment()`
  Email::Styles.class_eval do
    def initialize(html, opts=nil)
      @html = html
      @opts = opts || {}
      @fragment = Nokogiri::HTML(@html)
    end
  end

  # This is just a quick way of overriding the email/notification template.
  # The only thing that's changed here from the Discourse code is the path given
  # to UserNotificationRender.
  UserNotifications.class_eval do

    class UserNotificationRenderer < ActionView::Base
      include UserNotificationsHelper
    end

    def notification_view_path
      File.expand_path('../app/views', __FILE__)
    end

    def send_notification_email(opts)
      post = opts[:post]
      title = opts[:title]
      allow_reply_by_email = opts[:allow_reply_by_email]
      use_site_subject = opts[:use_site_subject]
      add_re_to_subject = opts[:add_re_to_subject] && post.post_number > 1
      username = opts[:username]
      from_alias = opts[:from_alias]
      notification_type = opts[:notification_type]
      user = opts[:user]

      # category name
      category = Topic.find_by(id: post.topic_id).category
      if opts[:show_category_in_subject] && post.topic_id && category && !category.uncategorized?
        show_category_in_subject = category.name

        # subcategory case
        if !category.parent_category_id.nil?
          show_category_in_subject = "#{Category.find_by(id: category.parent_category_id).name}/#{show_category_in_subject}"
        end
      else
        show_category_in_subject = nil
      end

      context = ""
      tu = TopicUser.get(post.topic_id, user)
      context_posts = self.class.get_context_posts(post, tu)

      # make .present? cheaper
      context_posts = context_posts.to_a

      if context_posts.present?
        context << "---\n*#{I18n.t('user_notifications.previous_discussion')}*\n"
        context_posts.each do |cp|
          context << email_post_markdown(cp)
        end
      end

      topic_excerpt = ""
      if opts[:use_template_html]
        topic_excerpt = post.excerpt.gsub("\n", " ") if post.is_first_post? && post.excerpt
      else
        # notification_view_path returns the plugin's view
        html = UserNotificationRenderer.new([notification_view_path]).render(
            template: 'email/notification',
            format: :html,
            locals: {context_posts: context_posts,
                     post: post,
                     classes: RTL.new(user).css_class
            }
        )
      end

      template = "user_notifications.user_#{notification_type}"
      if post.topic.private_message?
        template << "_pm"
        template << "_staged" if user.staged?
      end

      email_opts = {
          topic_title: title,
          topic_excerpt: topic_excerpt,
          message: email_post_markdown(post),
          url: post.url,
          post_id: post.id,
          topic_id: post.topic_id,
          context: context,
          username: username,
          add_unsubscribe_link: !user.staged,
          unsubscribe_url: post.topic.unsubscribe_url,
          allow_reply_by_email: allow_reply_by_email,
          use_site_subject: use_site_subject,
          add_re_to_subject: add_re_to_subject,
          show_category_in_subject: show_category_in_subject,
          private_reply: post.topic.private_message?,
          include_respond_instructions: !user.suspended?,
          template: template,
          html_override: html,
          site_description: SiteSetting.site_description,
          site_title: SiteSetting.title,
          style: :notification
      }

      # If we have a display name, change the from address
      email_opts[:from_alias] = from_alias if from_alias.present?

      TopicUser.change(user.id, post.topic_id, last_emailed_post_number: post.post_number)

      build_email(user.email, email_opts)
    end
  end


end