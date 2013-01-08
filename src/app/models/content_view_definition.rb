#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'util/model_util.rb'

class ContentViewDefinition < ActiveRecord::Base
  include Glue::ElasticSearch::ContentViewDefinition if AppConfig.use_elasticsearch
  include Katello::LabelFromName
  include Authorization::ContentViewDefinition

  include AsyncOrchestration

  has_many :content_views
  has_many :components, :class_name => "ComponentContentView"
  has_many :component_content_views, :through => :components,
    :source => :content_view, :class_name => "ContentView"
  belongs_to :organization, :inverse_of => :content_view_definitions
    has_many :content_view_definition_products
  has_many :products, :through => :content_view_definition_products
  has_many :content_view_definition_repositories
  has_many :repositories, :through => :content_view_definition_repositories

  validates :label, :uniqueness => {:scope => :organization_id},
    :presence => true, :katello_label_format => true
  validates :name, :presence => true, :katello_name_format => true
  validates :organization, :presence => true
  validate :validate_content

  def publish(name, description, label=nil, options = { })
    options = { :async => true, :notify => false }.merge options

    view = ContentView.create!(:name => name,
                        :label=>label,
                        :description => description,
                        :content_view_definition => self,
                        :organization => organization
                       )

    version = ContentViewVersion.create!(:version=>1, :content_view=>view,
                                 :environments => [organization.library])

    if options[:async]
      async_task = self.async(:organization => self.organization,
                              :task_type => TaskStatus::TYPES[:content_view_publish][:type]).
                        generate_repos(view, options[:notify])

      version.task_status = async_task
      version.save!
    else
      version.task_status = nil
      version.save!
      generate_repos(view, options[:notify])
    end

    view
  end

  def generate_repos(view, notify = false)
    async_tasks = []
    repos.each do |repo|
      clone = repo.create_clone(self.organization.library, view)
      async_tasks << repo.clone_contents(clone)
    end
    PulpTaskStatus::wait_for_tasks async_tasks.flatten(1)

    if notify
      message = _("Successfully published content view '%{view_name}' from definition '%{definition_name}'.") %
          {:view_name => view.name, :definition_name => self.name}

      Notify.success(message, :request_type => "content_view_definitions___publish",
                     :organization => self.organization)
    end

  rescue => e
    Rails.logger.error(e)
    Rails.logger.error(e.backtrace.join("\n"))

    if notify
      message = _("Failed to publish content view '%{view_name}' from definition '%{definition_name}'.") %
          {:view_name => view.name, :definition_name => self.name}


      Notify.exception(message, e, :request_type => "content_view_definitions___publish",
                       :organization => self.organization)
    end

    raise e
  end

  # Retrieve a list of repositories associated with the definition.
  # This includes all repositories (ie. combining those that are part of products associated with the definition
  # as well as repositories that are explicitly associated with the definition).
  def repos
    repos = []
    self.products.each do |prod|
      prod_repos = prod.repos(organization.library).enabled
      prod_repos.select{|r| r.in_default_view?}.each{|r| repos << r}
    end
    repos.concat(self.repositories)
    repos.uniq!
    repos
  end

  def composite?
    self.component_content_views.any?
  end

  def has_content?
    self.products.any? || self.repositories.any?
  end

  def as_json(options = {})
    result = self.attributes
    result["organization"] = self.organization.try(:name)
    result["content_views"] = self.content_views.map(&:label).join(", ")
    result["components"] = self.component_content_views.map(&:label).join(", ")
    result["products"] = products.map(&:name)
    result["repos"] = repositories.map(&:name)
    result
  end

  private

    def validate_content
      if has_content? && composite?
        errors.add(:base, _("cannot contai nproducts, or repositories if it contains views"))
      end
    end

end