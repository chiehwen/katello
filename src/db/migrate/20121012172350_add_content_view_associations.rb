class AddContentViewAssociations < ActiveRecord::Migration
  def self.up
    add_column :filters, :content_view_definition_id, :integer
    add_index :filters, :content_view_definition_id

    add_column :environments, :default_content_view_id, :integer
    add_index :environments, :default_content_view_id

    add_column :systems, :content_view_id, :integer
    add_index :systems, :content_view_id
  end

  def self.down
    remove_column :filters, :content_view_definition_id
    remove_column :repositories, :content_view_definition_id
    remove_column :environments, :default_content_view_id
    remove_column :systems, :content_view_id
  end
end